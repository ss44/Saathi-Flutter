import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:saathi/ui/transcript_latest.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'runtime_flow_test.dart' show runtimeCapabilities;
import 'ui/remote_participation_test.dart' show network;

class RefreshStore extends SaathiStore {
  RefreshStore({required super.preferences, required super.secrets});
  bool fail = false;
  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    if (fail) throw StateError('Controlled history failure');
    await super.saveChats(chats);
  }
}

class RefreshFixture {
  late ChatController c;
  late RefreshStore store;
  late http.Client client;
  final requests = <http.Request>[];
  final replies = <String>[];
  Completer<void>? gate;
  final remote = RemoteSession({
    'id': 'external',
    'source': 'api_server',
    'title': 'External chat',
    'model': 'original-model',
    'provider': 'original-provider',
  });
  List<Map<String, dynamic>> rows = [
    {'id': 1, 'role': 'user', 'content': 'Original input'},
    {'id': 2, 'role': 'assistant', 'content': 'Original answer'},
  ];
  int get reads =>
      requests.where((r) => r.url.path.endsWith('/messages')).length;
  Future<void> start() async {
    SharedPreferences.setMockInitialValues({});
    store = RefreshStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    client = MockClient((r) async {
      requests.add(r);
      expectSync(r.method, 'GET');
      expectSync(r.url.host, 'original.example');
      if (r.url.path.endsWith('/capabilities')) {
        return http.Response(jsonEncode(runtimeCapabilities), 200);
      }
      if (r.url.path == '/api/sessions') {
        return http.Response(
            jsonEncode({
              'data': [remote.data],
              'has_more': false
            }),
            200);
      }
      expectSync(r.url.path, '/api/sessions/external/messages');
      final snapshot = [...rows];
      await gate?.future;
      return http.Response(
          jsonEncode({
            'session_id': 'external',
            'data': snapshot,
            'pagination': {
              'offset': 0,
              'limit': 100,
              'returned': snapshot.length,
              'order': 'oldest'
            },
          }),
          200);
    });
    c = ChatController(store,
        coreFactory: () => SaathiCore(client: client),
        runClientFactory: (root, key) => RunClient(root, key, client: client));
    c.onReplyReceived = replies.add;
    await c.load();
    await c.addConnection({
      'id': 'original',
      'name': 'Original host',
      'type': 'hermes',
      'url': 'https://original.example'
    }, 'fixture');
  }

  Future<void> open() => c.continueRemote(c.connections.single, remote);
  void extend() => rows.add({
        'id': rows.length + 1,
        'role': 'assistant',
        'content': 'External new third row'
      });
  void close() {
    c.dispose();
    client.close();
  }
}

void main() {
  test(
      'unchanged idle refresh is a no-write no-completion identity-preserving no-op',
      () async {
    final f = RefreshFixture();
    await f.start();
    addTearDown(f.close);
    await f.open();
    final original = f.c.current!;
    final messages = [...original.messages];
    final generation = f.c.selectionGeneration;
    final stored = f.store.preferences.getString('saathi.chats.v1');
    f.store.fail = true;
    await f.open();
    expect(f.c.current, same(original));
    expect(f.c.selectionGeneration, generation);
    expect(original.messages, messages);
    for (var i = 0; i < messages.length; i++) {
      expect(original.messages[i], same(messages[i]));
    }
    expect(f.store.preferences.getString('saathi.chats.v1'), stored);
    expect(f.c.unsavedChanges, isFalse);
    expect(f.reads, 2);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
    expect(f.replies, isEmpty);
  });

  test(
      'refresh retains completion objects and retries history storage without another GET or POST',
      () async {
    final f = RefreshFixture();
    await f.start();
    addTearDown(f.close);
    await f.open();
    final original = f.c.current!;
    final answer = ChatMessage(
        role: 'model',
        content: 'Original answer',
        id: 'run-stable',
        metadata: {'authoritativeCompletion': true});
    original.messages[1] = answer;
    f.extend();
    f.store.fail = true;
    await expectLater(f.open(), throwsStateError);
    expect(f.c.current, same(original));
    expect(original.messages[1], same(answer));
    expect(original.messages.last.content, 'External new third row');
    expect(f.c.unsavedChanges, isTrue);
    expect(f.replies, isEmpty);
    expect(f.c.organization.entry(f.c.identityOf(original)).unread, isFalse);
    final reads = f.reads;
    f.store.fail = false;
    await f.c.retrySave();
    expect(f.c.unsavedChanges, isFalse);
    expect(f.reads, reads);
    expect((await f.store.load()).chats.single['messages'], hasLength(3));
    expect(original.messages[1].id, 'run-stable');
    expect(original.messages[1].metadata['authoritativeCompletion'], isTrue);
    expect(original.messages.last.metadata['authoritativeCompletion'], isNull);
    expect(f.replies, isEmpty);
    await f.open();
    expect(original.messages, hasLength(3),
        reason: 'Repeated import is idempotent');
    expect(original.messages[1], same(answer));
  });

  for (final boundary in [
    'accepted pending',
    'local newer answer',
    'selection roundtrip',
    'source replacement'
  ]) {
    test('delayed reopen cannot overwrite $boundary', () async {
      final f = RefreshFixture();
      await f.start();
      addTearDown(f.close);
      await f.open();
      final original = f.c.current!;
      final old = [...original.messages];
      f.extend();
      f.gate = Completer<void>();
      final opening = f.open();
      final rejected = expectLater(
          opening,
          ['selection roundtrip', 'source replacement'].contains(boundary)
              ? throwsStateError
              : throwsA(isA<RemoteContinuationUnavailable>()));
      for (var i = 0; i < 100 && f.reads < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(f.reads, 2);
      if (boundary == 'accepted pending') {
        expect(f.c.submit('Accepted locally while reading'), isTrue);
        f.c.pauseQueue('Deliberately held');
      } else if (boundary == 'local newer answer') {
        original.messages.add(ChatMessage(
            role: 'model',
            content: 'Newer local completion',
            id: 'run-newer',
            metadata: {'authoritativeCompletion': true}));
      } else if (boundary == 'selection roundtrip') {
        final other =
            ChatSession(id: 'other', connectionId: 'original', model: 'other');
        f.c.sessions.add(other);
        f.c.select(other);
        f.c.select(original);
      } else {
        await f.c.updateConnection('original', f.c.connections.single,
            apiKey: 'replacement');
      }
      f.gate!.complete();
      await rejected;
      for (var i = 0; i < 100 && f.c.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(f.c.current, same(original));
      expect(original.messages.take(2), old);
      expect(
          original.messages.any((m) => m.content == 'External new third row'),
          isFalse);
      if (boundary == 'accepted pending') {
        expect(f.c.outbox.single.text, 'Accepted locally while reading');
        expect(f.c.queueStatus, isNotNull);
      }
      if (boundary == 'local newer answer') {
        expect(original.messages.last.id, 'run-newer');
      }
      expect(f.requests.every((r) => r.method == 'GET'), isTrue);
      expect(f.replies, isEmpty);
    });
  }

  test('shorter or divergent remote snapshots never erase newer local rows',
      () async {
    final f = RefreshFixture();
    await f.start();
    addTearDown(f.close);
    await f.open();
    final original = f.c.current!;
    final before = [...original.messages];
    f.rows.removeLast();
    await expectLater(f.open(), throwsA(isA<RemoteContinuationUnavailable>()));
    expect(original.messages, before);
    f.rows = [
      {'id': 9, 'role': 'user', 'content': 'Different prefix'},
      {'id': 10, 'role': 'assistant', 'content': 'Different answer'},
      {'id': 11, 'role': 'assistant', 'content': 'Extra divergent row'},
    ];
    await expectLater(f.open(), throwsA(isA<RemoteContinuationUnavailable>()));
    expect(original.messages, before);
    expect(f.replies, isEmpty);
  });

  for (final longHistory in [false, true]) {
    testWidgets(
        'actual drawer reopens same idle chat with fresh history and keeps draft and reader long=$longHistory',
        (t) async {
      final f = RefreshFixture();
      await t.runAsync(() async {
        await f.start();
        if (longHistory) {
          f.rows = List.generate(
              30,
              (i) => {
                    'id': i,
                    'role': i.isEven ? 'user' : 'assistant',
                    'content': 'History row $i ${'long content ' * 20}'
                  });
        }
        await f.open();
      });
      addTearDown(f.close);
      final original = f.c.current!;
      final objects = [...original.messages];
      final generation = f.c.selectionGeneration;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(MaterialApp(home: ChatHome(controller: f.c)));
      await t.pumpAndSettle();
      await t.enterText(
          find.byKey(const Key('composer')), 'Keep this private draft');
      final list = find.descendant(
          of: find.byType(TranscriptLatest), matching: find.byType(ListView));
      final reader =
          find.descendant(of: list, matching: find.byType(Scrollable));
      // The history ListView, not EditableText's internal Scrollable.
      expect(list, findsOneWidget);
      await t.drag(list, const Offset(0, 300));
      await t.pumpAndSettle();
      final position = t.state<ScrollableState>(reader).position;
      if (longHistory) {
        position.jumpTo(position.maxScrollExtent / 2);
        await t.pumpAndSettle();
        await t.drag(list, const Offset(0, 100));
        await t.pumpAndSettle();
        expect(position.pixels, greaterThan(0));
        expect(position.extentAfter, greaterThan(position.viewportDimension));
      }
      final offset = position.pixels;
      f.extend();
      await t.tap(find.byTooltip('Settings'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Browse remote sessions'));
      await network(t);
      final row = find.descendant(
          of: find.byType(RemoteSessionsPage),
          matching: find.text('External chat'));
      await t.ensureVisible(row);
      await t.tap(row);
      await network(t);
      await t.pumpAndSettle();
      expect(f.c.current, same(original));
      expect(f.c.sessions, [original]);
      expect(original.messages.take(objects.length), objects);
      expect(original.messages.last.content, 'External new third row');
      expect(original.model, 'original-model');
      expect(original.upstreamProvider, 'original-provider');
      expect(original.connectionId, 'original');
      expect(original.remoteSessionId, 'external');
      expect(f.c.selectionGeneration, generation);
      expect(
          t
              .widget<TextField>(find.byKey(const Key('composer')))
              .controller!
              .text,
          'Keep this private draft');
      expect(t.state<ScrollableState>(reader).position, same(position));
      expect(position.pixels, closeTo(offset, 1));
      expect(f.reads, 2,
          reason: 'Initial attach plus single continuation GET without flash');
      expect(f.requests.every((r) => r.method == 'GET'), isTrue);
      expect(f.replies, isEmpty);
      await t.drag(list, const Offset(0, -3000));
      await t.pumpAndSettle();
      // Content is reconciled into the real message list, not just the preview.
      await t.scrollUntilVisible(find.text('External new third row'), 400,
          scrollable: reader);
      expect(find.text('External new third row').hitTestable(), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  }
}
