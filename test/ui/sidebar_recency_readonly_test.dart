import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/chat_organization/organization_widgets.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/conversation_servers.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:saathi/ui/transcript_presentation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gateway/canonical_combined_controller_test.dart' show NativeHost;
import '../runtime_flow_test.dart' show runtimeCapabilities;

double _contrastRatio(Color a, Color b) {
  final lumA = a.computeLuminance();
  final lumB = b.computeLuminance();
  final brightest = lumA > lumB ? lumA : lumB;
  final darkest = lumA > lumB ? lumB : lumA;
  return (brightest + 0.05) / (darkest + 0.05);
}

Future<SaathiStore> _makeStore([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SaathiStore(
    preferences: await SharedPreferences.getInstance(),
    secrets: MemorySecrets(),
  );
}

void main() {
  group('Timestamp extraction and message recency', () {
    test(
      'ChatMessage.timestamp parses ISO-8601 strings and epoch seconds/ms',
      () {
        final iso = ChatMessage(
          role: 'user',
          content: 'ISO',
          metadata: const {'timestamp': '2026-11-20T14:30:00Z'},
        );
        expect(iso.timestamp, DateTime.utc(2026, 11, 20, 14, 30));

        final seconds = ChatMessage(
          role: 'model',
          content: 'Seconds',
          metadata: const {'created_at': 1700000000},
        );
        expect(
          seconds.timestamp,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true),
        );

        final millis = ChatMessage(
          role: 'model',
          content: 'Millis',
          metadata: const {'createdAt': 1700000005000},
        );
        expect(
          millis.timestamp,
          DateTime.fromMillisecondsSinceEpoch(1700000005000, isUtc: true),
        );

        final updated = ChatMessage(
          role: 'user',
          content: 'Updated',
          metadata: const {'updated_at': '1700000010'},
        );
        expect(
          updated.timestamp,
          DateTime.fromMillisecondsSinceEpoch(1700000010 * 1000, isUtc: true),
        );

        final invalid = ChatMessage(
          role: 'user',
          content: 'Invalid',
          metadata: const {'timestamp': 'not-a-timestamp', 'created_at': -5},
        );
        expect(invalid.timestamp, isNull);
        expect(parseMessageTimestamp(1700000000000000000), isNull);
        expect(parseMessageTimestamp(1e30), isNull);
        expect(parseMessageTimestamp(double.infinity), isNull);
        expect(parseMessageTimestamp(double.nan), isNull);
      },
    );

    test(
      'SaathiStore.saveChats persists valid ISO-8601 timestamps and drops invalid or oversized ones',
      () async {
        final store = await _makeStore();
        await store.saveChats([
          {
            'id': 'c1',
            'connectionId': 'a',
            'model': 'm',
            'messages': [
              {
                'role': 'user',
                'content': 'valid',
                'metadata': {'timestamp': '2026-11-21T10:00:00.000Z'},
              },
              {
                'role': 'model',
                'content': 'invalid',
                'metadata': {'timestamp': 'not-a-date'},
              },
              {
                'role': 'model',
                'content': 'oversized',
                'metadata': {'timestamp': '2026-11-21T10:00:00Z${' ' * 60}'},
              },
            ],
          },
        ]);
        final messages = (await store.load()).chats.single['messages'] as List;
        expect(
          (messages[0] as Map)['metadata']['timestamp'],
          '2026-11-21T10:00:00.000Z',
        );
        expect(
          ((messages[1] as Map)['metadata'] as Map).containsKey('timestamp'),
          isFalse,
        );
        expect(
          ((messages[2] as Map)['metadata'] as Map).containsKey('timestamp'),
          isFalse,
        );
      },
    );

    test(
        'projectRemoteHistory records UTC ISO-8601 timestamp when present on remote row',
        () {
      final projected = projectRemoteHistory({
        'role': 'assistant',
        'content': 'Projected answer',
        'created_at': 1700000120,
      });
      expect(projected, isNotNull);
      expect(
        projected!.metadata['timestamp'],
        DateTime.fromMillisecondsSinceEpoch(
          1700000120 * 1000,
          isUtc: true,
        ).toIso8601String(),
      );

      final withoutTimestamp = projectRemoteHistory({
        'role': 'user',
        'content': 'Plain prompt',
      });
      expect(withoutTimestamp, isNotNull);
      expect(withoutTimestamp!.metadata, isEmpty);
    });

    test(
        'ChatSession.latestMessageAt uses visible bubbles first and falls back to any message timestamp',
        () {
      final session = ChatSession(
        id: 's1',
        connectionId: 'c1',
        model: 'm1',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Question',
            metadata: const {'timestamp': '2026-11-20T10:00:00Z'},
          ),
          ChatMessage(
            role: 'model',
            content: 'Visible answer',
            metadata: const {'timestamp': '2026-11-20T10:05:00Z'},
          ),
          ChatMessage(
            role: 'model',
            content: 'Tool activity: search',
            metadata: const {
              'canonicalRowKind': 'toolActivity',
              'timestamp': '2026-11-20T10:09:00Z',
            },
          ),
          ChatMessage(
            role: 'model',
            content: '   ',
            metadata: const {'timestamp': '2026-11-20T10:10:00Z'},
          ),
        ],
      );
      expect(session.latestMessageAt, DateTime.utc(2026, 11, 20, 10, 5));

      final fallbackOnly = ChatSession(
        id: 's2',
        connectionId: 'c1',
        model: 'm1',
        messages: [
          ChatMessage(
            role: 'model',
            content: '   ',
            metadata: const {'timestamp': '2026-11-20T11:00:00Z'},
          ),
        ],
      );
      expect(fallbackOnly.latestMessageAt, DateTime.utc(2026, 11, 20, 11, 0));
    });

    test(
        'RemoteSession.latestMessageAt extracts message/update timestamps and ignores created_at',
        () {
      expect(
        RemoteSession({
          'id': 'r1',
          'last_message_at': '2026-11-21T08:00:00Z',
          'created_at': '2026-11-19T08:00:00Z',
        }).latestMessageAt,
        DateTime.utc(2026, 11, 21, 8, 0),
      );
      expect(
        RemoteSession({'id': 'r2', 'lastMessageAt': 1700000200000})
            .latestMessageAt,
        DateTime.fromMillisecondsSinceEpoch(1700000200000, isUtc: true),
      );
      expect(
        RemoteSession({'id': 'r3', 'last_message_timestamp': 1700000300})
            .latestMessageAt,
        DateTime.fromMillisecondsSinceEpoch(1700000300 * 1000, isUtc: true),
      );
      expect(
        RemoteSession({'id': 'r4', 'updated_at': '2026-11-21T09:15:00Z'})
            .latestMessageAt,
        DateTime.utc(2026, 11, 21, 9, 15),
      );
      expect(
        RemoteSession({
          'id': 'r5',
          'created_at': '2026-11-21T12:00:00Z',
          'createdAt': '2026-11-21T12:00:00Z',
        }).latestMessageAt,
        isNull,
      );
    });
  });

  group('isSessionReadOnly and local session ordering', () {
    test(
        'isSessionReadOnly distinguishes active connections, removed sources, quarantined inputs, and connected vs disconnected hermesGateway',
        () async {
      final host = NativeHost();
      await host.start();
      addTearDown(host.close);

      final c = ChatController(await _makeStore());
      addTearDown(c.dispose);
      await c.load();
      await c.addConnection({
        'id': 'direct',
        'name': 'Direct OpenAI',
        'type': 'openai',
        'url': 'https://api.openai.com',
      }, 'secret');
      await c.addConnection({
        'id': 'gateway',
        'name': 'Hermes Desktop',
        'type': 'hermesGateway',
        'url': host.url,
      }, '');
      final gatewayConnection =
          c.connections.singleWhere((conn) => conn['id'] == 'gateway');

      final activeSession = ChatSession(
        id: 'active',
        connectionId: 'direct',
        model: 'gpt-4o',
      );
      final orphanedSession = ChatSession(
        id: 'orphaned',
        connectionId: 'removed-conn',
        model: 'gpt-4o',
      );
      final disconnectedGatewaySession = ChatSession(
        id: 'saved-gateway',
        connectionId: gatewayConnection['id'] as String,
        remoteSessionId: 'unattached-session',
        canonicalProfileId: 'profile-1',
        model: 'Hermes Desktop / CLI',
      );
      c.sessions.addAll([
        activeSession,
        orphanedSession,
        disconnectedGatewaySession,
      ]);

      expect(c.isSessionReadOnly(activeSession), isFalse);
      expect(c.isSessionReadOnly(orphanedSession), isTrue);
      expect(c.isSessionReadOnly(disconnectedGatewaySession), isTrue);

      c.select(activeSession);
      expect(c.readOnly, isFalse);
      c.select(orphanedSession);
      expect(c.readOnly, isTrue);

      final listed = await c.connectCanonical(
        gatewayConnection,
        host.invite,
      );
      await c.attachCanonical(listed.first);
      final attachedGatewaySession = c.current!;
      expect(c.isSessionReadOnly(attachedGatewaySession), isFalse);
      expect(c.readOnly, isFalse);
      // Another saved hermesGateway session that is not the attached one remains read-only.
      expect(c.isSessionReadOnly(disconnectedGatewaySession), isTrue);
    });

    test(
        'new incoming direct and Runs messages update timestamp and resort to top while selection and status polling do not',
        () async {
      var runCompleted = false;
      final client = MockClient((r) async {
        if (r.url.path == '/v1/chat/completions') {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Fresh direct reply'},
                },
              ],
            }),
            200,
          );
        }
        if (r.url.path.endsWith('/capabilities')) {
          return http.Response(jsonEncode(runtimeCapabilities), 200);
        }
        if (r.url.path.endsWith('/v1/runs') && r.method == 'POST') {
          return http.Response(
            jsonEncode({'run_id': 'run-1', 'status': 'running'}),
            202,
          );
        }
        if (r.url.path.endsWith('/v1/runs/run-1')) {
          return http.Response(
            jsonEncode(
              runCompleted
                  ? {
                      'run_id': 'run-1',
                      'status': 'completed',
                      'output': 'Completed run reply',
                    }
                  : {'run_id': 'run-1', 'status': 'running'},
            ),
            200,
          );
        }
        throw StateError('Unexpected ${r.method} ${r.url}');
      });

      final c = ChatController(
        await _makeStore(),
        coreFactory: () => SaathiCore(client: client),
        runClientFactory: (root, key) => RunClient(root, key, client: client),
      );
      addTearDown(c.dispose);
      await c.load();

      await c.addConnection({
        'id': 'direct',
        'name': 'Direct',
        'type': 'openai',
        'url': 'https://direct.example',
      }, 'key');
      await c.addConnection({
        'id': 'hermes',
        'name': 'Hermes API',
        'type': 'hermes',
        'url': 'https://hermes.example',
      }, 'key');

      final olderInteractive = ChatSession(
        id: 'older-interactive',
        connectionId: 'direct',
        model: 'm1',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Older chat',
            metadata: const {'timestamp': '2026-11-20T08:00:00Z'},
          ),
        ],
      );
      final newerInteractive = ChatSession(
        id: 'newer-interactive',
        connectionId: 'hermes',
        model: 'm2',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Newer chat',
            metadata: const {'timestamp': '2026-11-20T09:00:00Z'},
          ),
        ],
      );
      final newestReadOnly = ChatSession(
        id: 'newest-readonly',
        connectionId: 'removed',
        model: 'm3',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Very recent read-only chat',
            metadata: const {'timestamp': '2026-11-21T12:00:00Z'},
          ),
        ],
      );
      final olderReadOnly = ChatSession(
        id: 'older-readonly',
        connectionId: 'removed',
        model: 'm3',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Older read-only chat',
            metadata: const {'timestamp': '2026-11-19T12:00:00Z'},
          ),
        ],
      );

      c.sessions.addAll([
        olderInteractive,
        newerInteractive,
        olderReadOnly,
        newestReadOnly,
      ]);

      expect(c.orderedSessions().map((s) => s.id), [
        'newer-interactive',
        'older-interactive',
        'newest-readonly',
        'older-readonly',
      ]);

      // Selecting an older chat must NOT change its sort position.
      c.select(olderInteractive);
      expect(c.orderedSessions().map((s) => s.id), [
        'newer-interactive',
        'older-interactive',
        'newest-readonly',
        'older-readonly',
      ]);

      // Completing a new direct reply on olderInteractive records a UTC timestamp and moves it to the top.
      expect(await c.send('Follow-up question'), isTrue);
      expect(
        olderInteractive.messages.last.metadata['timestamp'],
        isA<String>(),
      );
      expect(c.orderedSessions().map((s) => s.id), [
        'older-interactive',
        'newer-interactive',
        'newest-readonly',
        'older-readonly',
      ]);

      // Starting a run and polling while still 'running' must NOT move newerInteractive above olderInteractive.
      c.select(newerInteractive);
      expect(await c.send('Run prompt'), isTrue);
      await c.checkRunStatus(sessionId: newerInteractive.id);
      expect(c.orderedSessions().map((s) => s.id), [
        'older-interactive',
        'newer-interactive',
        'newest-readonly',
        'older-readonly',
      ]);

      // Once the run completes, its message timestamp updates and resorts newerInteractive to the top.
      runCompleted = true;
      await c.checkRunStatus(sessionId: newerInteractive.id);
      expect(
        newerInteractive.messages.last.metadata['timestamp'],
        isA<String>(),
      );
      expect(c.orderedSessions().map((s) => s.id), [
        'newer-interactive',
        'older-interactive',
        'newest-readonly',
        'older-readonly',
      ]);
    });

    test(
        'equal or missing timestamps preserve deterministic c.sessions.reversed order within each group',
        () async {
      final c = ChatController(await _makeStore());
      addTearDown(c.dispose);
      await c.load();
      await c.addConnection({
        'id': 'active',
        'name': 'Active',
        'type': 'openai',
        'url': 'https://example.com',
      }, 'key');

      final tiedFirst = ChatSession(
        id: 'tied-first',
        connectionId: 'active',
        model: 'm',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Tied 1',
            metadata: const {'timestamp': '2026-11-20T10:00:00Z'},
          ),
        ],
      );
      final tiedSecond = ChatSession(
        id: 'tied-second',
        connectionId: 'active',
        model: 'm',
        messages: [
          ChatMessage(
            role: 'user',
            content: 'Tied 2',
            metadata: const {'timestamp': '2026-11-20T10:00:00Z'},
          ),
        ],
      );
      final noTsFirst = ChatSession(
        id: 'nots-first',
        connectionId: 'active',
        model: 'm',
        messages: [ChatMessage(role: 'user', content: 'No TS 1')],
      );
      final noTsSecond = ChatSession(
        id: 'nots-second',
        connectionId: 'active',
        model: 'm',
        messages: [ChatMessage(role: 'user', content: 'No TS 2')],
      );
      final roFirst = ChatSession(
        id: 'ro-first',
        connectionId: 'gone',
        model: 'm',
        messages: [ChatMessage(role: 'user', content: 'RO 1')],
      );
      final roSecond = ChatSession(
        id: 'ro-second',
        connectionId: 'gone',
        model: 'm',
        messages: [ChatMessage(role: 'user', content: 'RO 2')],
      );

      c.sessions.addAll([
        tiedFirst,
        tiedSecond,
        noTsFirst,
        noTsSecond,
        roFirst,
        roSecond,
      ]);

      // sessions.reversed has tiedSecond before tiedFirst, noTsSecond before noTsFirst, roSecond before roFirst.
      expect(c.orderedSessions().map((s) => s.id), [
        'tied-second',
        'tied-first',
        'nots-second',
        'nots-first',
        'ro-second',
        'ro-first',
      ]);
    });
  });

  group('Sidebar, ConversationOrganizationList, and remote session widgets',
      () {
    for (final width in [360.0, 390.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'ChatHome drawer groups interactive above read-only by recency with neutral gray styling and Read-only semantics at ${width}px 2x $brightness',
          (tester) async {
            tester.view.physicalSize = Size(width, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final semantics = tester.ensureSemantics();
            try {
              final c = ChatController(await _makeStore());
              addTearDown(c.dispose);
              await c.load();
              await c.addConnection({
                'id': 'api-1',
                'name': 'Primary API',
                'type': 'openai',
                'url': 'https://api.example.com',
              }, 'secret');

              final apiOlder = ChatSession(
                id: 'api-older',
                connectionId: 'api-1',
                model: 'gpt-4',
                messages: [
                  ChatMessage(
                    role: 'user',
                    content: 'API older chat',
                    metadata: const {'timestamp': '2026-11-20T09:00:00Z'},
                  ),
                ],
              );
              final roNewer = ChatSession(
                id: 'ro-newer',
                connectionId: 'deleted-conn',
                model: 'old-model',
                messages: [
                  ChatMessage(
                    role: 'user',
                    content: 'Read-only newer chat',
                    metadata: const {'timestamp': '2026-11-21T15:00:00Z'},
                  ),
                ],
              );
              final apiNewer = ChatSession(
                id: 'api-newer',
                connectionId: 'api-1',
                model: 'gpt-4',
                messages: [
                  ChatMessage(
                    role: 'user',
                    content: 'API newer chat',
                    metadata: const {'timestamp': '2026-11-21T11:00:00Z'},
                  ),
                ],
              );
              final roOlder = ChatSession(
                id: 'ro-older',
                connectionId: 'deleted-conn',
                model: 'old-model',
                messages: [
                  ChatMessage(
                    role: 'user',
                    content: 'Read-only older chat',
                    metadata: const {'timestamp': '2026-11-18T10:00:00Z'},
                  ),
                ],
              );
              c.sessions.addAll([apiOlder, roNewer, apiNewer, roOlder]);
              c.select(apiNewer);

              final theme = ThemeData(
                useMaterial3: true,
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF3E6559),
                  brightness: brightness,
                ),
              );

              await tester.pumpWidget(
                MaterialApp(
                  theme: theme,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: const TextScaler.linear(2)),
                    child: child!,
                  ),
                  home: ChatHome(controller: c),
                ),
              );
              await tester.pumpAndSettle();

              await tester.tap(find.byTooltip('Open navigation menu'));
              await tester.pumpAndSettle();

              final rows = tester
                  .widgetList<ConversationActionRow>(
                    find.byType(ConversationActionRow),
                  )
                  .toList();
              expect(rows.map((r) => r.row.title), [
                'API newer chat',
                'API older chat',
                'Read-only newer chat',
                'Read-only older chat',
              ]);
              expect(rows[0].readOnly, isFalse);
              expect(rows[1].readOnly, isFalse);
              expect(rows[2].readOnly, isTrue);
              expect(rows[3].readOnly, isTrue);

              // Verify vertical visual ordering in the drawer.
              final y0 = tester.getTopLeft(find.text('API newer chat')).dy;
              final y1 = tester.getTopLeft(find.text('API older chat')).dy;
              final y2 =
                  tester.getTopLeft(find.text('Read-only newer chat')).dy;
              final y3 =
                  tester.getTopLeft(find.text('Read-only older chat')).dy;
              expect(y0, lessThan(y1));
              expect(y1, lessThan(y2));
              expect(y2, lessThan(y3));

              // Verify subtle neutral gray background & legibility contrast in light & dark themes.
              final expectedGray = readOnlyConversationTileColor(
                tester.element(find.byType(Drawer)),
              );
              expect(expectedGray.r, closeTo(expectedGray.g, 0.01));
              expect(expectedGray.g, closeTo(expectedGray.b, 0.01));
              expect(expectedGray, isNot(equals(theme.colorScheme.surface)));

              final interactiveTile = tester.widget<ListTile>(
                find.descendant(
                  of: find.byWidget(rows[0]),
                  matching: find.byType(ListTile),
                ),
              );
              final readOnlyTile = tester.widget<ListTile>(
                find.descendant(
                  of: find.byWidget(rows[2]),
                  matching: find.byType(ListTile),
                ),
              );
              expect(interactiveTile.tileColor, isNull);
              expect(readOnlyTile.tileColor, expectedGray);
              expect(
                _contrastRatio(theme.colorScheme.onSurface, expectedGray),
                greaterThanOrEqualTo(4.5),
              );
              expect(
                _contrastRatio(
                  theme.colorScheme.onSurfaceVariant,
                  expectedGray,
                ),
                greaterThanOrEqualTo(4.5),
              );

              // Visible Read-only badge and screen-reader semantics.
              expect(
                find.descendant(
                  of: find.byWidget(rows[2]),
                  matching: find.text('Read-only'),
                ),
                findsOneWidget,
              );
              expect(
                tester
                    .getSemantics(
                      find.descendant(
                        of: find.byWidget(rows[2]),
                        matching: find.byType(ListTile),
                      ),
                    )
                    .label,
                contains('Read-only'),
              );

              // Read-only conversation remains selectable for viewing history.
              await tester.tap(find.text('Read-only newer chat'));
              await tester.pumpAndSettle();
              expect(c.current, same(roNewer));
              expect(c.readOnly, isTrue);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }

    testWidgets(
      'deleting a connection demotes its chats to the read-only group below remaining interactive chats and preserves search & selection',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final c = ChatController(await _makeStore());
        addTearDown(c.dispose);
        await c.load();
        await c.addConnection({
          'id': 'conn-a',
          'name': 'Connection A',
          'type': 'openai',
          'url': 'https://a.example.com',
        }, 'key-a');
        await c.addConnection({
          'id': 'conn-b',
          'name': 'Connection B',
          'type': 'openai',
          'url': 'https://b.example.com',
        }, 'key-b');

        final chatA = ChatSession(
          id: 'chat-a',
          connectionId: 'conn-a',
          model: 'model-a',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Alpha latest message',
              metadata: const {'timestamp': '2026-11-21T16:00:00Z'},
            ),
          ],
        );
        final chatB = ChatSession(
          id: 'chat-b',
          connectionId: 'conn-b',
          model: 'model-b',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Beta older message',
              metadata: const {'timestamp': '2026-11-21T10:00:00Z'},
            ),
          ],
        );
        c.sessions.addAll([chatB, chatA]);
        c.select(chatA);

        await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
        await tester.pumpAndSettle();

        // Initially both are interactive, so chatA (16:00) is above chatB (10:00).
        var rows = tester
            .widgetList<ConversationActionRow>(
              find.byType(ConversationActionRow),
            )
            .toList();
        expect(rows.map((r) => r.row.title), [
          'Alpha latest message',
          'Beta older message',
        ]);
        expect(rows[0].selected, isTrue);

        // Delete conn-a: chatA becomes read-only and moves below interactive chatB.
        await c.deleteConnection('conn-a');
        await tester.pumpAndSettle();

        rows = tester
            .widgetList<ConversationActionRow>(
              find.byType(ConversationActionRow),
            )
            .toList();
        expect(rows.map((r) => r.row.title), [
          'Beta older message',
          'Alpha latest message',
        ]);
        expect(rows[0].readOnly, isFalse);
        expect(rows[1].readOnly, isTrue);
        // Selected state on wide desktop layout is preserved even when read-only.
        expect(rows[1].selected, isTrue);

        // Local search preserves interactive-first recency order.
        await tester.enterText(
          find.byKey(const Key('local-history-search')),
          'message',
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        rows = tester
            .widgetList<ConversationActionRow>(
              find.byType(ConversationActionRow),
            )
            .toList();
        expect(rows.map((r) => r.row.title), [
          'Beta older message',
          'Alpha latest message',
        ]);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'ConversationOrganizationList groups interactive rows above read-only rows by latestMessageAt',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final org = ChatOrganization(
          OrganizationStorage(await SharedPreferences.getInstance()),
        );
        await org.load();

        const roNewest = ConversationIdentity('c', 'ro-newest');
        const interactiveOld = ConversationIdentity('c', 'int-old');
        const interactiveNew = ConversationIdentity('c', 'int-new');
        const roOlder = ConversationIdentity('c', 'ro-older');

        ConversationIdentity? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConversationOrganizationList(
                organization: org,
                rows: [
                  ConversationRowData(
                    identity: roNewest,
                    title: 'RO Newest',
                    readOnly: true,
                    latestMessageAt: DateTime.utc(2026, 11, 21, 18, 0),
                  ),
                  ConversationRowData(
                    identity: interactiveOld,
                    title: 'Interactive Older',
                    latestMessageAt: DateTime.utc(2026, 11, 20, 12, 0),
                  ),
                  ConversationRowData(
                    identity: interactiveNew,
                    title: 'Interactive Newer',
                    latestMessageAt: DateTime.utc(2026, 11, 21, 12, 0),
                  ),
                  ConversationRowData(
                    identity: roOlder,
                    title: 'RO Older',
                    readOnly: true,
                    latestMessageAt: DateTime.utc(2026, 11, 19, 12, 0),
                  ),
                ],
                onSelect: (id) => selected = id,
                onEdit: (_) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final rows = tester
            .widgetList<ConversationActionRow>(
              find.byType(ConversationActionRow),
            )
            .toList();
        expect(rows.map((r) => r.row.title), [
          'Interactive Newer',
          'Interactive Older',
          'RO Newest',
          'RO Older',
        ]);
        expect(rows[2].readOnly, isTrue);
        await tester.tap(find.text('RO Newest'));
        await tester.pumpAndSettle();
        expect(selected, roNewest);
      },
    );

    testWidgets(
      'ConversationServer and RemoteSessionsPage sort api_server chats by recency above read-only sessions and style read-only rows',
      (tester) async {
        var runSubmissionSupported = true;
        final client = MockClient((r) async {
          if (r.url.path == '/v1/capabilities') {
            return http.Response(
              jsonEncode({
                'features': {'run_submission': runSubmissionSupported},
              }),
              200,
            );
          }
          if (r.url.path == '/api/sessions') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'cli-recent',
                    'title': 'CLI Most Recent',
                    'source': 'cli',
                    'last_message_at': '2026-11-21T20:00:00Z',
                  },
                  {
                    'id': 'api-older',
                    'title': 'API Older Chat',
                    'source': 'api_server',
                    'updated_at': '2026-11-20T10:00:00Z',
                  },
                  {
                    'id': 'desktop-older',
                    'title': 'Desktop Older',
                    'source': 'desktop',
                    'updated_at': '2026-11-19T08:00:00Z',
                  },
                  {
                    'id': 'api-newer',
                    'title': 'API Newer Chat',
                    'source': 'api_server',
                    'last_message_at': '2026-11-21T14:00:00Z',
                  },
                ],
                'has_more': false,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          throw StateError('Unexpected ${r.url}');
        });

        final c = ChatController(
          await _makeStore(),
          coreFactory: () => SaathiCore(client: client),
        );
        addTearDown(c.dispose);
        await c.load();
        final connection = <String, dynamic>{
          'id': 'hermes-1',
          'name': 'Hermes Host',
          'type': 'hermes',
          'url': 'https://hermes.example',
        };
        c.connections.add(connection);

        final cache = ConversationServerCache(c, connection);
        addTearDown(cache.dispose);
        await cache.load();

        expect(cache.sessions.map((s) => s.id), [
          'api-newer',
          'api-older',
          'cli-recent',
          'desktop-older',
        ]);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ConversationServer(
                  cache: cache,
                  closeDrawerOnOpen: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final expectedGray = readOnlyConversationTileColor(
          tester.element(find.byType(ConversationServer)),
        );
        final apiTile = tester.widget<ListTile>(
          find.widgetWithText(ListTile, 'API Newer Chat'),
        );
        final cliTile = tester.widget<ListTile>(
          find.widgetWithText(ListTile, 'CLI Most Recent'),
        );
        expect(apiTile.tileColor, isNull);
        expect(cliTile.tileColor, expectedGray);
        expect(
          find.descendant(
            of: find.widgetWithText(ListTile, 'CLI Most Recent'),
            matching: find.text('Read-only'),
          ),
          findsOneWidget,
        );

        // When capabilities explicitly report run_submission: false, even api_server is read-only.
        runSubmissionSupported = false;
        await cache.load(refresh: true);
        await tester.pumpAndSettle();
        final disabledApiTile = tester.widget<ListTile>(
          find.widgetWithText(ListTile, 'API Newer Chat'),
        );
        expect(disabledApiTile.tileColor, expectedGray);

        // Verify RemoteSessionsPage ordering and Read-only label when run_submission is enabled.
        runSubmissionSupported = true;
        await tester.pumpWidget(
          MaterialApp(
            home: RemoteSessionsPage(controller: c, connection: connection),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        final remoteTitles = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((tile) => (tile.title! as Text).data)
            .toList();
        expect(remoteTitles, [
          'API Newer Chat',
          'API Older Chat',
          'CLI Most Recent',
          'Desktop Older',
        ]);
        final pageCliTile = tester.widget<ListTile>(
          find.widgetWithText(ListTile, 'CLI Most Recent'),
        );
        expect(pageCliTile.tileColor, expectedGray);
        expect(
          find.descendant(
            of: find.widgetWithText(ListTile, 'CLI Most Recent'),
            matching: find.text('Read-only'),
          ),
          findsOneWidget,
        );

        // When run_submission is false on RemoteSessionsPage, api_server shows Runs unavailable, not Gateway connection required.
        runSubmissionSupported = false;
        await tester.pumpWidget(
          MaterialApp(
            home: RemoteSessionsPage(
              key: const ValueKey('runs-unavailable'),
              controller: c,
              connection: connection,
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        final unavailableApiTile = find.widgetWithText(
          ListTile,
          'API Newer Chat',
        );
        expect(
          find.descendant(
            of: unavailableApiTile,
            matching: find.text('api_server · Runs unavailable'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: unavailableApiTile,
            matching: find.text('Read-only'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: unavailableApiTile,
            matching: find.textContaining('Gateway connection required'),
          ),
          findsNothing,
        );
      },
    );
  });
}
