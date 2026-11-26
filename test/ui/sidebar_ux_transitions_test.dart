import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/conversation_servers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingChatStore extends SaathiStore {
  _FailingChatStore(SharedPreferences preferences)
      : super(preferences: preferences, secrets: MemorySecrets());
  bool failSaveChats = false;

  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    if (failSaveChats) throw StateError('simulated disk error');
    await super.saveChats(chats);
  }
}

Future<SaathiStore> _makeStore([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SaathiStore(
    preferences: await SharedPreferences.getInstance(),
    secrets: MemorySecrets(),
  );
}

void main() {
  group('Sidebar scannability, archive/search clarity and remote filtering',
      () {
    testWidgets(
      'shows connection name + model subtitles, hides Archived (0) and empty clear button, and hides remote servers in Archived/search',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final client = MockClient((request) async {
          if (request.url.path == '/v1/capabilities') {
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/sessions') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'remote-1',
                    'title': 'Server Remote Session',
                    'source': 'api_server',
                  },
                ],
                'has_more': false,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        });
        addTearDown(client.close);

        final store = await _makeStore();
        final c = ChatController(
          store,
          coreFactory: () => SaathiCore(client: client),
        );
        await c.load();
        await c.addConnection({
          'id': 'work-openai',
          'name': 'Work OpenAI',
          'type': 'openai',
          'url': 'https://work.example',
        }, 'secret-1');
        await c.addConnection({
          'id': 'hermes-1',
          'name': 'Lab Hermes',
          'type': 'hermes',
          'url': 'https://hermes.example',
        }, 'secret-2');

        final active = ChatSession(
          id: 'active-chat',
          connectionId: 'work-openai',
          model: 'gpt-4o',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Quarterly planning notes',
              metadata: const {'timestamp': '2026-11-21T10:00:00Z'},
            ),
          ],
        );
        final orphaned = ChatSession(
          id: 'orphan-chat',
          connectionId: 'removed-conn',
          model: 'legacy-model',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Archived legacy question',
              metadata: const {'timestamp': '2026-11-20T10:00:00Z'},
            ),
          ],
        );
        c.sessions.addAll([orphaned, active]);
        c.select(active);

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
        for (var i = 0; i < 6; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
        }
        await tester.pumpAndSettle();

        final drawer = find.byType(Drawer);

        // Connection name + model replaces repetitive "On this device · <model>".
        expect(find.textContaining('On this device ·'), findsNothing);
        expect(
          find.descendant(
            of: drawer,
            matching: find.text('Work OpenAI · gpt-4o'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: drawer,
            matching: find.text('Unavailable connection · legacy-model'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: drawer, matching: find.text('Read-only')),
          findsOneWidget,
        );

        // Archived (0) toggle is hidden when there are no archived chats.
        expect(find.byKey(const Key('archived-view')), findsNothing);
        expect(find.textContaining('Archived (0)'), findsNothing);

        // Search clear (X) button is hidden while search input is empty.
        expect(find.byTooltip('Clear search'), findsNothing);

        // Remote server rows are visible in normal recent view.
        expect(find.byType(ConversationServer), findsOneWidget);
        expect(find.text('Server Remote Session'), findsOneWidget);

        // Typing a search query immediately shows Clear search and hides remote servers.
        final search = find.byKey(const Key('local-history-search'));
        await tester.enterText(search, 'Quarterly');
        await tester.pump();
        expect(find.byTooltip('Clear search'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();

        expect(find.byType(ConversationServer), findsNothing);
        expect(find.text('Server Remote Session'), findsNothing);
        expect(
          find.descendant(
            of: drawer,
            matching: find.textContaining('Work OpenAI · gpt-4o'),
          ),
          findsOneWidget,
        );

        // Clearing search hides Clear search again and restores remote server rows.
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Clear search'), findsNothing);
        expect(find.byType(ConversationServer), findsOneWidget);
        expect(find.text('Server Remote Session'), findsOneWidget);

        // Archiving a chat reveals the Archived toggle; entering Archived hides remote servers.
        await c.organization.setArchived(c.identityOf(orphaned), true);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('archived-view')), findsOneWidget);
        expect(find.text('Archived (1)'), findsOneWidget);

        await tester.tap(find.byKey(const Key('archived-view')));
        await tester.pumpAndSettle();
        expect(find.text('Back to recent conversations'), findsOneWidget);
        expect(find.byType(ConversationServer), findsNothing);
        expect(find.text('Server Remote Session'), findsNothing);
        expect(
          find.descendant(
            of: drawer,
            matching: find.text('Archived legacy question'),
          ),
          findsOneWidget,
        );

        // Restoring the last archived chat keeps "Back to recent conversations" visible
        // while still inside Archived view, then hides the toggle once back in recent.
        await c.organization.setArchived(c.identityOf(orphaned), false);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('archived-view')), findsOneWidget);
        expect(find.text('Back to recent conversations'), findsOneWidget);

        await tester.tap(find.byKey(const Key('archived-view')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('archived-view')), findsNothing);
        expect(find.byType(ConversationServer), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  });

  group('Startup selection and delete transitions', () {
    test(
      'ChatController.load selects top active non-archived non-read-only chat with clean fallbacks',
      () async {
        final store = await _makeStore();
        await store.saveConnection({
          'id': 'active-conn',
          'name': 'Active',
          'type': 'openai',
          'url': 'https://active.example',
        }, apiKey: 'key');

        final olderActive = ChatSession(
          id: 'older-active',
          connectionId: 'active-conn',
          model: 'm1',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Older active',
              metadata: const {'timestamp': '2026-11-20T08:00:00Z'},
            ),
          ],
        );
        final topActive = ChatSession(
          id: 'top-active',
          connectionId: 'active-conn',
          model: 'm1',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Top active',
              metadata: const {'timestamp': '2026-11-21T09:00:00Z'},
            ),
          ],
        );
        final archivedNewest = ChatSession(
          id: 'archived-newest',
          connectionId: 'active-conn',
          model: 'm1',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Archived newest',
              metadata: const {'timestamp': '2026-11-22T12:00:00Z'},
            ),
          ],
        );
        final readOnlyLast = ChatSession(
          id: 'readonly-last',
          connectionId: 'removed-conn',
          model: 'm1',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Read-only last in list',
              metadata: const {'timestamp': '2026-11-22T15:00:00Z'},
            ),
          ],
        );

        await store.saveChats([
          olderActive.toJson(),
          topActive.toJson(),
          archivedNewest.toJson(),
          readOnlyLast.toJson(),
        ]);

        final seed = ChatController(store);
        await seed.load();
        await seed.organization.setArchived(
          seed.identityOf(archivedNewest),
          true,
        );
        seed.dispose();

        // Reload: must pick topActive (not readOnlyLast or archivedNewest).
        final c1 = ChatController(store);
        await c1.load();
        expect(c1.current?.id, 'top-active');
        c1.dispose();

        // Fallback 1: when all non-archived chats are read-only, pick top non-archived.
        await store.changeConnection('active-conn');
        final c2 = ChatController(store);
        await c2.load();
        expect(c2.current?.id, 'readonly-last');
        c2.dispose();

        // Fallback 2: when all chats are archived, pick orderedSessions().first.
        await store.saveChats([archivedNewest.toJson()]);
        final c3 = ChatController(store);
        await c3.load();
        expect(c3.current?.id, 'archived-newest');
        c3.dispose();
      },
    );

    test(
      'deleteSession and clear fall back to next active chat, preserve safety guards, and roll back on persist failure',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = _FailingChatStore(await SharedPreferences.getInstance());
        final c = ChatController(store);
        addTearDown(c.dispose);
        await c.load();
        await c.addConnection({
          'id': 'conn',
          'name': 'Primary',
          'type': 'openai',
          'url': 'https://example.com',
        }, 'key');

        final readOnly = ChatSession(
          id: 'ro',
          connectionId: 'removed',
          model: 'm',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'RO',
              metadata: const {'timestamp': '2026-11-22T10:00:00Z'},
            ),
          ],
        );
        final secondActive = ChatSession(
          id: 'second',
          connectionId: 'conn',
          model: 'm',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Second active',
              metadata: const {'timestamp': '2026-11-21T08:00:00Z'},
            ),
          ],
        );
        final topActive = ChatSession(
          id: 'top',
          connectionId: 'conn',
          model: 'm',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Top active',
              metadata: const {'timestamp': '2026-11-21T12:00:00Z'},
            ),
          ],
        );
        c.sessions.addAll([readOnly, secondActive, topActive]);
        await c.persist();
        c.select(topActive);

        // Persist failure rolls back sessions and keeps current unchanged.
        store.failSaveChats = true;
        await expectLater(c.clear(), throwsStateError);
        expect(c.current, same(topActive));
        expect(c.sessions.map((s) => s.id), ['ro', 'second', 'top']);
        store.failSaveChats = false;

        // Held prepared input blocks deletion of that session without mutating state.
        await store.preferences.setString(
          ChatController.preparedInputsKey,
          jsonEncode([
            QueuedFollowup('held', secondActive, {
              'type': 'openai',
              'url': 'https://example.com',
              'authorityEpoch': null,
            }).preparedJson('dispatched'),
          ]),
        );
        final guarded = ChatController(store);
        addTearDown(guarded.dispose);
        await guarded.load();
        final guardedSecond =
            guarded.sessions.singleWhere((s) => s.id == 'second');
        expect(guarded.canDeleteSession(guardedSecond), isFalse);
        await expectLater(
          guarded.deleteSession(guardedSecond),
          throwsStateError,
        );
        expect(guarded.sessions.map((s) => s.id), contains('second'));
        await store.preferences.remove(ChatController.preparedInputsKey);

        // Deleting topActive falls back to secondActive (not readOnly or null).
        await c.clear();
        expect(c.current, same(secondActive));
        expect(c.sessions.map((s) => s.id), ['ro', 'second']);

        // Deleting secondActive falls back to remaining readOnly chat.
        await c.clear();
        expect(c.current, same(readOnly));
        expect(c.sessions.map((s) => s.id), ['ro']);

        // Deleting the last remaining chat sets current to null.
        await c.clear();
        expect(c.current, isNull);
        expect(c.sessions, isEmpty);
      },
    );

    testWidgets(
      'row overflow menu Delete confirms, deletes non-selected without changing active draft, and falls back when deleting active',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final c = ChatController(await _makeStore());
        addTearDown(c.dispose);
        await c.load();
        final conn = {
          'id': 'conn',
          'name': 'Primary',
          'type': 'openai',
          'url': 'https://example.com',
        };
        await c.addConnection(conn, 'key');
        final chatA = ChatSession(
          id: 'chat-a',
          connectionId: 'conn',
          model: 'model-a',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Chat Alpha',
              metadata: const {'timestamp': '2026-11-20T09:00:00Z'},
            ),
          ],
        );
        final chatB = ChatSession(
          id: 'chat-b',
          connectionId: 'conn',
          model: 'model-b',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Chat Beta',
              metadata: const {'timestamp': '2026-11-21T09:00:00Z'},
            ),
          ],
        );
        final chatC = ChatSession(
          id: 'chat-c',
          connectionId: 'conn',
          model: 'model-c',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Chat Gamma',
              metadata: const {'timestamp': '2026-11-22T09:00:00Z'},
            ),
          ],
        );
        c.sessions.addAll([chatA, chatB, chatC]);
        await c.persist();
        c.select(chatC);

        await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
        await tester.pumpAndSettle();

        final composer = find.byKey(const Key('composer'));
        await tester.enterText(composer, 'Active draft in Gamma');
        await tester.pump();

        // Open row overflow menu on non-selected Chat Alpha and tap Keep.
        final alphaRow = find.byKey(ValueKey(c.identityOf(chatA).storageKey));
        await tester.tap(
          find.descendant(
            of: alphaRow,
            matching: find.byTooltip('Conversation actions'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete').last);
        await tester.pumpAndSettle();
        expect(find.text('Delete this conversation?'), findsOneWidget);
        await tester.tap(find.text('Keep'));
        await tester.pumpAndSettle();
        expect(c.sessions, contains(chatA));
        expect(c.current, same(chatC));

        // Confirm Delete on non-selected Chat Alpha: keeps Gamma selected and draft intact.
        await tester.tap(
          find.descendant(
            of: alphaRow,
            matching: find.byTooltip('Conversation actions'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete').last);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Delete'),
          ),
        );
        await tester.pumpAndSettle();
        expect(c.sessions, isNot(contains(chatA)));
        expect(c.current, same(chatC));
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'Active draft in Gamma',
        );

        // Confirm Delete on active Chat Gamma via row menu: falls back to Chat Beta and clears draft.
        final gammaRow = find.byKey(ValueKey(c.identityOf(chatC).storageKey));
        await tester.tap(
          find.descendant(
            of: gammaRow,
            matching: find.byTooltip('Conversation actions'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete').last);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Delete'),
          ),
        );
        await tester.pumpAndSettle();
        expect(c.sessions, [chatB]);
        expect(c.current, same(chatB));
        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('Recovery and read-only banner actions', () {
    testWidgets(
      'read-only disconnected banner offers New conversation when connections exist and Add connection when none',
      (tester) async {
        final c = ChatController(await _makeStore());
        addTearDown(c.dispose);
        await c.load();

        final orphaned = ChatSession(
          id: 'orphaned',
          connectionId: 'gone',
          model: 'old-model',
          messages: [ChatMessage(role: 'user', content: 'Old message')],
        );
        c.sessions.add(orphaned);
        c.select(orphaned);

        await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
        await tester.pumpAndSettle();

        final bannerButton = find.byKey(const Key('readonly-new-chat'));
        expect(bannerButton, findsOneWidget);
        expect(
          find.descendant(
            of: bannerButton,
            matching: find.text('Add connection'),
          ),
          findsOneWidget,
        );

        await tester.tap(bannerButton);
        await tester.pumpAndSettle();
        expect(find.byType(AddConnectionPage), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();

        // Add a connection: banner quick action switches to "New conversation" and opens NewChatPage.
        await c.addConnection({
          'id': 'live',
          'name': 'Live API',
          'type': 'openai',
          'url': 'https://live.example',
        }, 'secret');
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: bannerButton,
            matching: find.text('New conversation'),
          ),
          findsOneWidget,
        );
        await tester.tap(bannerButton);
        await tester.pumpAndSettle();
        expect(find.byType(NewChatPage), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'startup storage error screen offers Try again and loads stored data intact without wiping',
      (tester) async {
        final store = await _makeStore();
        await store.saveConnection({
          'id': 'saved-conn',
          'name': 'Saved API',
          'type': 'openai',
          'url': 'https://saved.example',
        }, apiKey: 'saved-secret');
        await store.saveChats([
          {
            'id': 'saved-chat',
            'connectionId': 'saved-conn',
            'model': 'gpt-4o',
            'messages': [
              {'role': 'user', 'content': 'Persisted greeting'},
            ],
          },
        ]);

        var attempts = 0;
        await tester.pumpWidget(
          SaathiApp(
            storeOpener: () async {
              attempts++;
              if (attempts == 1) {
                throw StateError('transient secure storage error');
              }
              return store;
            },
          ),
        );
        await tester.pumpAndSettle();

        expect(attempts, 1);
        expect(
          find.textContaining('Secure storage could not be opened'),
          findsOneWidget,
        );
        expect(find.text('Try again'), findsOneWidget);
        // Stored data remains untouched after failure.
        expect((await store.load()).chats, hasLength(1));

        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();

        expect(attempts, 2);
        expect(find.byType(ChatHome), findsOneWidget);
        expect(find.text('Persisted greeting'), findsAtLeastNWidgets(1));
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('Small-screen 360px / 2x text layout safety', () {
    testWidgets(
      'drawer subtitles, search clear, row Delete menu, read-only banner and startup retry have zero overflow at 360px 2x',
      (tester) async {
        tester.view.physicalSize = const Size(360, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.reset);

        // 1) Startup storage error screen at 360px / 2x text.
        await tester.pumpWidget(
          SaathiApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            storeOpener: () async => throw StateError('storage unavailable'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Try again'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 2) ChatHome read-only banner + drawer at 360px / 2x text + keyboard insets.
        final c = ChatController(await _makeStore());
        addTearDown(c.dispose);
        await c.load();
        await c.addConnection({
          'id': 'conn',
          'name': 'Very Long Connection Name For Mobile',
          'type': 'openai',
          'url': 'https://example.com',
        }, 'secret');
        final active = ChatSession(
          id: 'active',
          connectionId: 'conn',
          model: 'model-with-a-long-identifier',
          messages: [ChatMessage(role: 'user', content: 'Mobile active chat')],
        );
        final orphaned = ChatSession(
          id: 'orphaned',
          connectionId: 'deleted',
          model: 'old-model',
          messages: [ChatMessage(role: 'user', content: 'Orphaned chat')],
        );
        c.sessions.addAll([active, orphaned]);
        c.select(orphaned);

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: ChatHome(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('readonly-new-chat')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('archived-view')), findsNothing);
        expect(find.byTooltip('Clear search'), findsNothing);

        await tester.enterText(
          find.byKey(const Key('local-history-search')),
          'Mobile',
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Clear search'), findsOneWidget);
        expect(
          find.textContaining('Very Long Connection Name For Mobile'),
          findsOneWidget,
        );

        await tester.tap(find.byTooltip('Conversation actions').first);
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
