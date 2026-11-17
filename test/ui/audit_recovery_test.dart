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
  });

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
