import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ActivityController extends ChatController {
  _ActivityController(super.store, {super.coreFactory});
  final observations = StreamController<ScopedRunSnapshot>.broadcast();
  @override
  Stream<ScopedRunSnapshot> get scopedRunSnapshots => observations.stream;
  @override
  void dispose() {
    observations.close();
    super.dispose();
  }
}

class _DelayedSecrets extends MemorySecrets {
  Completer<String?>? gate;
  @override
  Future<String?> read(String id) => gate?.future ?? super.read(id);
}

void main() {
  late SaathiStore store;
  late int posts;
  final a = ChatSession(id: 'a-chat', connectionId: 'a', model: 'model');
  final b = ChatSession(id: 'b-chat', connectionId: 'b', model: 'model');
  ChatController controller() => ChatController(store,
      coreFactory: () => SaathiCore(client: MockClient((_) async {
            posts++;
            return http.Response(
                '{"choices":[{"message":{"content":"answer"}}]}', 200);
          })));

  setUp(() async {
    posts = 0;
    a.messages.clear();
    b.messages.clear();
    SharedPreferences.setMockInitialValues({});
    store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    for (final id in ['a', 'b']) {
      await store.saveConnection({
        'id': id,
        'name': id,
        'type': 'openai',
        'url': 'https://$id.test',
        'authorityEpoch': 'original',
      }, apiKey: 'fixture');
    }
    await store.saveChats([a.toJson(), b.toJson()]);
  });

  for (final cause in ['deleted chat', 'deleted connection', 'changed key']) {
    for (final state in ['prepared', 'dispatched']) {
      test('$cause $state recovery is retained without blocking source B',
          () async {
        final saved = jsonEncode([
          QueuedFollowup(
                  'retained private input',
                  a,
                  {
                    'type': 'openai',
                    'url': 'https://a.test',
                    'authorityEpoch': 'original',
                  },
                  replyId: 'held-reply')
              .preparedJson(state)
        ]);
        await store.preferences
            .setString(ChatController.preparedInputsKey, saved);
        if (cause == 'deleted chat') {
          await store.saveChats([b.toJson()]);
        } else if (cause == 'deleted connection') {
          await store.changeConnection('a');
        } else {
          await store.changeConnection('a',
              replacement: {
                'id': 'a',
                'name': 'a',
                'type': 'openai',
                'url': 'https://a.test',
                'authorityEpoch': 'replacement',
              },
              apiKey: 'replacement-fixture');
        }
        final c = controller();
        addTearDown(c.dispose);
        await c.load();
        c.select(c.sessions.singleWhere((s) => s.id == b.id));
        expect(c.readOnly, isFalse);
        expect(await c.send('independent input'), isTrue);
        expect(posts, 1);
        final held = c.sessions.singleWhere((s) => s.id == a.id);
        c.select(held);
        expect(c.readOnly, isTrue);
        expect(c.uncertainInput?.text, 'retained private input');
        expect(c.canResumeQueue, isFalse);
        c.resumeQueue();
        expect(await c.send('must not send'), isFalse);
        expect(posts, 1);
        final row = (jsonDecode(store.preferences
                .getString(ChatController.preparedInputsKey)!) as List)
            .single;
        expect(row['quarantined'], isTrue);
        expect(Map<String, dynamic>.from(row)..remove('quarantined'),
            (jsonDecode(saved) as List).single);
        final restored = controller();
        await restored.load();
        restored.select(restored.sessions.singleWhere((s) => s.id == a.id));
        expect(restored.readOnly, isTrue);
        expect(restored.canResumeQueue, isFalse);
        expect(restored.uncertainInput?.text, 'retained private input');
        restored.dispose();
        await c.abandonHeldOutbox(held);
        expect(c.uncertainInput, isNull);
        expect(
            jsonDecode(
                store.preferences.getString(ChatController.preparedInputsKey)!),
            isEmpty);
        expect(posts, 1);
      });
    }
  }

  test('deletion cannot orphan unresolved recovery evidence', () async {
    await store.preferences.setString(
        ChatController.preparedInputsKey,
        jsonEncode([
          QueuedFollowup('held', a, {
            'type': 'openai',
            'url': 'https://a.test',
            'authorityEpoch': 'original',
          }).preparedJson('dispatched')
        ]));
    final c = controller();
    addTearDown(c.dispose);
    await c.load();
    c.select(c.sessions.first);
    await expectLater(c.clear(), throwsStateError);
    expect(c.sessions, hasLength(2));
    expect(c.uncertainInput?.text, 'held');
  });

  test('completion capacity blocks only its original chat across restart',
      () async {
    a.messages.add(ChatMessage(
        role: 'model',
        content: 'retained answer',
        id: 'reply-512',
        metadata: {'authoritativeCompletion': true}));
    await store.saveChats([a.toJson(), b.toJson()]);
    await store.preferences.setString(
        OrganizationStorage.key,
        jsonEncode({
          'schema': 1,
          'chats': {
            const ConversationIdentity('a', 'a-chat').storageKey: {
              'displayName': '',
              'archived': false,
              'completions': {for (var i = 0; i < 512; i++) 'reply-$i': true}
            }
          },
          'personas': []
        }));
    for (var restart = 0; restart < 2; restart++) {
      final c = controller();
      await c.load();
      c.select(c.sessions.singleWhere((s) => s.id == b.id));
      expect(c.organizationBlocked, isFalse);
      expect(await c.send('independent $restart'), isTrue);
      c.select(c.sessions.singleWhere((s) => s.id == a.id));
      expect(c.organizationBlocked, isTrue);
      expect(c.current!.messages.single.content, 'retained answer');
      await c.retryOrganizationSave();
      expect(c.organizationBlocked, isTrue);
      expect(c.organization.entry(c.identityOf(c.current!)).completions,
          hasLength(512));
      c.dispose();
    }
    expect(posts, 2);
  });

  test(
      'whole-ledger 1,000-chat capacity isolates the 1,001st chat across retry and restart without duplicate unread or notifications',
      () async {
    final seed = ChatOrganization(OrganizationStorage(store.preferences));
    await seed.load();
    await seed.recordCompletion(
        const ConversationIdentity('a', 'a-chat'), 'reply-a0');
    for (var i = 1; i < 1000; i++) {
      await seed.recordCompletion(
          ConversationIdentity('a', 'chat-$i'), 'reply-0');
    }
    a.messages.add(ChatMessage(
        role: 'model',
        content: 'existing answer',
        id: 'reply-a0',
        metadata: {'authoritativeCompletion': true}));
    await store.saveChats([a.toJson(), b.toJson()]);

    final notifications = <String>[];
    final c = controller()..onReplyReceived = notifications.add;
    await c.load();

    // Select the 1,001st conversation identity (b-chat) and complete a reply.
    c.select(c.sessions.singleWhere((s) => s.id == b.id));
    expect(c.organizationBlocked, isFalse);
    expect(await c.send('1001st question'), isTrue);
    expect(posts, 1);
    expect(notifications, [b.id]);
    expect(c.current!.messages.last.content, 'answer');
    expect(c.organization.hasUnsavedChanges, isFalse);
    expect(c.organizationBlocked, isTrue);
    expect(c.organizationProblem,
        contains('This conversation reached its saved reply-details limit.'));
    expect(c.organizationProblem,
        contains('Other conversations remain available.'));

    await c.retryOrganizationSave();
    expect(c.organizationBlocked, isTrue);
    expect(c.organization.hasUnsavedChanges, isFalse);
    expect(notifications, [b.id]);
    expect(posts, 1);

    // Existing chat among the 1,000 remains unblocked, can mark visible and send.
    final healthyA = c.sessions.singleWhere((s) => s.id == a.id);
    c.select(healthyA);
    expect(c.organizationBlocked, isFalse);
    expect(c.organizationProblem, isNull);
    expect(c.organization.entry(c.identityOf(healthyA)).unread, isTrue);
    await c.replyVisible(healthyA, 'reply-a0');
    expect(c.organization.entry(c.identityOf(healthyA)).unread, isFalse);
    expect(await c.send('follow-up in existing chat'), isTrue);
    expect(posts, 2);
    expect(notifications, [b.id, a.id]);
    final secondReplyId = healthyA.messages.last.id!;
    expect(c.organization.entry(c.identityOf(healthyA)).unreadCompletionIds,
        [secondReplyId]);
    await c.replyVisible(healthyA, secondReplyId);
    expect(c.organization.entry(c.identityOf(healthyA)).unread, isFalse);
    c.dispose();

    // Restart preserves retained answer, isolates 1,001st chat, and creates no duplicate unread/notification.
    final restored = controller()..onReplyReceived = notifications.add;
    addTearDown(restored.dispose);
    await restored.load();
    expect(notifications, [b.id, a.id]);

    final restoredA = restored.sessions.singleWhere((s) => s.id == a.id);
    restored.select(restoredA);
    expect(restored.organizationBlocked, isFalse);
    expect(restored.organizationProblem, isNull);
    expect(restored.organization.entry(restored.identityOf(restoredA)).unread,
        isFalse);
    expect(await restored.send('post-restart in existing chat'), isTrue);
    expect(posts, 3);
    expect(notifications, [b.id, a.id, a.id]);
    await restored.replyVisible(restoredA, restoredA.messages.last.id!);
    expect(restored.organization.entry(restored.identityOf(restoredA)).unread,
        isFalse);

    final restoredB = restored.sessions.singleWhere((s) => s.id == b.id);
    restored.select(restoredB);
    expect(restored.organizationBlocked, isTrue);
    expect(restored.organizationProblem,
        contains('This conversation reached its saved reply-details limit.'));
    expect(restoredB.messages.last.content, 'answer');
  });

  test(
      'serialized 2 MiB organization byte limit isolates overflowing chat and rejects oversized edits without blocking healthy chat',
      () async {
    const limit = 2 * 1024 * 1024;
    const identityA = ConversationIdentity('a', 'a-chat');
    final chats = <String, dynamic>{
      for (var i = 0; i < 130; i++)
        ConversationIdentity('a', 'filler-$i').storageKey: {
          'displayName': '',
          'archived': false,
          'instructions': 'i' * 16000,
          'completions': <String, bool>{},
        },
      identityA.storageKey: {
        'displayName': 'Chat A',
        'archived': false,
        'instructions': '',
        'completions': {'reply-a0': false},
      },
    };
    final baseLength =
        jsonEncode({'schema': 1, 'chats': chats, 'personas': []}).length;
    final pad = limit - baseLength - 18;
    (chats[identityA.storageKey] as Map<String, dynamic>)['instructions'] =
        'p' * pad;
    a.messages.add(ChatMessage(
        role: 'model',
        content: 'initial A answer',
        id: 'reply-a0',
        metadata: {'authoritativeCompletion': true}));
    await store.saveChats([a.toJson(), b.toJson()]);
    await store.preferences.setString(OrganizationStorage.key,
        jsonEncode({'schema': 1, 'chats': chats, 'personas': []}));

    final c = controller();
    addTearDown(c.dispose);
    await c.load();

    // Completing a reply in B exceeds the 2 MiB serialized ledger budget.
    final sessionB = c.sessions.singleWhere((s) => s.id == b.id);
    c.select(sessionB);
    expect(await c.send('overflow 2 MiB in B'), isTrue);
    expect(posts, 1);
    expect(sessionB.messages.last.content, 'answer');
    expect(c.organization.hasUnsavedChanges, isFalse);
    expect(c.organizationBlocked, isTrue);
    expect(c.organizationProblem,
        contains('This conversation reached its saved reply-details limit.'));

    // Switching to A keeps A unblocked and able to mark its reply visible.
    final sessionA = c.sessions.singleWhere((s) => s.id == a.id);
    c.select(sessionA);
    expect(c.organizationBlocked, isFalse);
    expect(c.organizationProblem, isNull);
    await c.replyVisible(sessionA, 'reply-a0');
    expect(c.organization.entry(identityA).unread, isFalse);

    // An oversized edit on A is rejected before pending state can block A.
    await expectLater(
      c.organization.edit(
        identityA,
        displayName: 'x' * 80,
        personaId: null,
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null,
      ),
      throwsStateError,
    );
    expect(c.organization.hasUnsavedChanges, isFalse);
    expect(c.organizationBlocked, isFalse);
    expect(c.organizationProblem, isNull);

    // Freeing instruction space in A and retrying unblocks B's retained completion.
    await c.saveChatSettings(
      sessionA,
      originalConnection:
          c.connections.singleWhere((conn) => conn['id'] == 'a'),
      selection: c.selectionGeneration,
      model: 'model',
      instructions: 'short',
      personaId: null,
    );
    await c.retryOrganizationSave();
    c.select(sessionB);
    expect(c.organizationBlocked, isFalse);
    expect(c.organizationProblem, isNull);
    expect(c.organization.entry(c.identityOf(sessionB)).unreadCompletionIds,
        [sessionB.messages.last.id]);
  });

  test('oversized direct input is refused before journal or queue mutation',
      () async {
    final c = controller();
    addTearDown(c.dispose);
    await c.load();
    final input = 'x' * (256 * 1024 + 1);
    expect(c.submit(input), isFalse);
    expect(await c.send(input), isFalse);
    expect(c.outbox, isEmpty);
    expect(
        store.preferences.getString(ChatController.preparedInputsKey), isNull);
    expect(posts, 0);
  });

  test('admission bounds accept exact limits and reject oversized instructions',
      () async {
    final c = controller();
    addTearDown(c.dispose);
    await c.load();
    await c.newSession(c.connections.last, 'model', 'i' * 16000);
    expect(await c.send('x' * ChatController.maxInputLength), isTrue);
    expect(posts, 1);
    await c.newSession(c.connections.last, 'model', 'i' * 16001);
    expect(c.submit('must stay in composer'), isFalse);
    expect(await c.send('must not dispatch'), isFalse);
    expect(c.outbox, isEmpty);
    expect(posts, 1);
  });

  testWidgets('notification selection never transfers a draft to another chat',
      (t) async {
    final c = controller();
    await c.load();
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    final composer = find.byKey(const Key('composer'));
    await t.enterText(composer, 'B private draft');
    expect(c.openNotificationConversation(b.id), isTrue);
    await t.pump();
    expect(t.widget<TextField>(composer).controller!.text, 'B private draft');
    expect(c.openNotificationConversation(a.id), isTrue);
    await t.pump();
    expect(t.widget<TextField>(composer).controller!.text, isEmpty);
    expect(posts, 0);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Android status-only run stays out of the composer controls',
      (t) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 800);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final c = _ActivityController(store);
    await c.load();
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(2),
                viewInsets: const EdgeInsets.only(bottom: 220)),
            child: child!),
        home: ChatHome(controller: c)));
    expect(c.usesRunStatusSync, isTrue);
    for (final status in ['running', 'waiting_for_approval']) {
      c.observations.add(ScopedRunSnapshot(
          localChatId: a.id,
          connectionId: 'a',
          connectionRevision: Object(),
          operationKey: 'activity-operation',
          originalAuthority: {},
          originalConnection: c.connections.first,
          snapshot: RunSnapshot({'run_id': 'activity-run', 'status': status}),
          isCurrent: () => true));
      await t.pump();
      expect(find.text('Agent activity'), findsNothing);
      expect(find.text('Needs your attention'), findsNothing);
      expect(find.byKey(const Key('composer')), findsOneWidget);
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('activity navigation revokes preparing input across a round trip',
      (t) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    a.messages.add(ChatMessage(role: 'user', content: 'Activity parent A'));
    await store.saveChats([a.toJson(), b.toJson()]);
    final secrets = _DelayedSecrets();
    final c = _ActivityController(
        SaathiStore(preferences: store.preferences, secrets: secrets),
        coreFactory: () => SaathiCore(client: MockClient((_) async {
              posts++;
              return http.Response(
                  '{"choices":[{"message":{"content":"answer"}}]}', 200);
            })));
    await c.load();
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    final selected = c.current!;
    c.observations.add(ScopedRunSnapshot(
        localChatId: a.id,
        connectionId: 'a',
        connectionRevision: Object(),
        operationKey: 'activity-operation',
        originalAuthority: {},
        originalConnection: c.connections.first,
        snapshot: RunSnapshot({'run_id': 'activity-run', 'status': 'running'}),
        isCurrent: () => true));
    await t.pump();
    secrets.gate = Completer<String?>();
    expect(c.submit('held during navigation'), isTrue);
    await t.pump();
    await t.tap(find.text('Agent activity'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.ensureVisible(find.text('Activity parent A'));
    await t.tap(find.text('Activity parent A'));
    await t.pump(const Duration(milliseconds: 400));
    expect(c.current!.id, a.id);
    c.select(selected);
    secrets.gate!.complete('fixture');
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await t.pump();
    expect(posts, 0);
    expect(c.outbox.single.text, 'held during navigation');
    expect(c.queueStatus, isNotNull);
    expect(c.canResumeQueue, isTrue);
    c.resumeQueue();
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(posts, 1);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('pending direct input stays in its owning conversation',
      (t) async {
    final response = Completer<http.Response>();
    final c = ChatController(store,
        coreFactory: () =>
            SaathiCore(client: MockClient((_) => response.future)));
    await c.load();
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    late Future<bool> sending;
    await t.runAsync(() async {
      sending = c.send('B pending input');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    c.select(c.sessions.first);
    await t.pump();
    expect(find.text('B pending input'), findsNothing);
    expect(find.text('Waiting for reply'), findsNothing);
    await t.runAsync(() async {
      response.complete(http.Response(
          '{"choices":[{"message":{"content":"B answer"}}]}', 200));
      await sending;
    });
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
