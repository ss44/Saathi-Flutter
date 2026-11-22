import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'agent_runs_test.dart' show capabilities;

class SyncFixture {
  final requests = <String>[];
  int posts = 0;
  int historyReads = 0;
  int statusReads = 0;
  bool losePostAck = true;
  bool historyFails = false;
  String? overrideHistorySessionId;
  List<Map<String, dynamic>> history = [
    {'id': 1, 'role': 'user', 'content': 'hello'},
    {'id': 2, 'role': 'assistant', 'content': 'Old reply'},
  ];
  String runStatus = 'running';
  String runOutput = 'Live status reply';
  Completer<void>? historyGate;

  Future<http.Response> handle(http.Request request) async {
    requests.add('${request.method} ${request.url.path}');
    if (request.url.path.endsWith('/capabilities')) {
      return http.Response(jsonEncode(capabilities), 200);
    }
    if (request.method == 'POST' && request.url.path.endsWith('/v1/runs')) {
      posts++;
      if (losePostAck && posts == 1) {
        return http.Response('{"error":{"code":"timeout"}}', 504);
      }
      return http.Response(
          jsonEncode({'run_id': 'run_post_$posts', 'status': 'running'}), 202);
    }
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      historyReads++;
      if (historyGate != null) {
        final gate = historyGate!;
        historyGate = null;
        await gate.future;
      }
      if (historyFails) {
        return http.Response('{"error":"unavailable"}', 503);
      }
      final segments = request.url.pathSegments;
      final sessionId = segments[segments.length - 2];
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
      final limit = int.parse(request.url.queryParameters['limit'] ?? '100');
      final slice = offset >= history.length
          ? <Map<String, dynamic>>[]
          : history.sublist(
              offset,
              offset + limit > history.length
                  ? history.length
                  : offset + limit);
      return http.Response(
          jsonEncode({
            'session_id': overrideHistorySessionId ?? sessionId,
            'data': slice,
            'pagination': {
              'offset': offset,
              'limit': limit,
              'returned': slice.length,
              'has_more': offset + slice.length < history.length,
            },
          }),
          200);
    }
    if (request.method == 'GET' && request.url.path.contains('/v1/runs/')) {
      statusReads++;
      final runId = request.url.pathSegments.last;
      return http.Response(
          jsonEncode({
            'run_id': runId,
            'status': runStatus,
            if (runStatus == 'completed') 'output': runOutput,
          }),
          200);
    }
    return http.Response('{}', 404);
  }
}

Future<ChatController> createController(
  SyncFixture fixture, {
  bool withExistingHistory = true,
  String? remoteSessionId = 'sess_1',
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets());
  final c = ChatController(
    store,
    coreFactory: () => SaathiCore(client: MockClient(fixture.handle)),
    runClientFactory: (root, key) =>
        RunClient(root, key, client: MockClient(fixture.handle)),
  );
  await c.load();
  await c.addConnection({
    'id': 'h',
    'name': 'Hermes',
    'type': 'hermes',
    'url': 'https://hermes.example',
  }, 'fixture');
  final session = ChatSession(
    id: 'chat_1',
    connectionId: 'h',
    remoteSessionId: remoteSessionId,
    model: 'hermes-model',
    messages: withExistingHistory
        ? [
            ChatMessage(role: 'user', content: 'hello'),
            ChatMessage(role: 'model', content: 'Old reply'),
          ]
        : [],
  );
  c.sessions.add(session);
  c.select(session);
  await c.persist();
  return c;
}

void main() {
  test(
      'lost receipt refreshes chat history, skips old duplicate text, and syncs reply by string match',
      () async {
    final fixture = SyncFixture();
    final c = await createController(fixture);
    addTearDown(c.dispose);
    var notifications = 0;
    c.onReplyReceived = (_) => notifications++;

    expect(await c.send('hello'), isTrue);
    expect(fixture.posts, 1);
    expect(c.runPending, isTrue);
    expect(c.currentRun!.runId, isNull);
    expect(c.showPendingThinking, isTrue);
    expect(c.runObservationProblem, contains('Refreshing chat'));
    expect(c.submit('queued after sync'), isTrue);

    // Server still only has the old turn with identical text "hello".
    await c.checkRunStatus();
    expect(fixture.historyReads, 1);
    expect(fixture.posts, 1);
    expect(c.runPending, isTrue,
        reason: 'Old duplicate user text must never settle the new turn');
    expect(c.current!.messages, hasLength(2));

    // Server records the new user message, reply still generating.
    fixture.history = [
      ...fixture.history,
      {'id': 3, 'role': 'user', 'content': '  hello \r\n'},
    ];
    await c.checkRunStatus();
    expect(c.runPending, isTrue);
    expect(c.showPendingThinking, isTrue);
    expect(c.runObservationProblem, contains('Message received'));
    expect(fixture.posts, 1);

    // Server finishes and writes the assistant reply.
    fixture.history = [
      ...fixture.history,
      {
        'id': 4,
        'role': 'assistant',
        'content': 'Second synced reply',
        'timestamp': '2026-11-22T18:00:05Z',
      },
    ];
    await c.checkRunStatus();
    expect(c.currentRun!.committed, isTrue);
    expect(c.current!.messages.map((m) => m.content),
        ['hello', 'Old reply', 'hello', 'Second synced reply']);
    expect(c.current!.messages.last.metadata['serverMessageId'], '4');
    expect(notifications, 1);
    expect(c.runObservationProblem, isNull);
    // Queued follower dispatches now that the synced turn committed.
    for (var i = 0; i < 40 && fixture.posts < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(fixture.posts, 2);
  });

  test(
      'lost receipt recovers missing run_id by string match and switches to live status',
      () async {
    final fixture = SyncFixture();
    final c = await createController(fixture,
        withExistingHistory: false, remoteSessionId: null);
    addTearDown(c.dispose);
    fixture.history = [];

    expect(await c.send('run my build'), isTrue);
    expect(fixture.posts, 1);
    expect(c.currentRun!.runId, isNull);

    fixture.history = [
      {
        'id': 'm1',
        'role': 'user',
        'content': 'run my build',
        'run_id': 'run_recovered_42',
      },
    ];
    await c.checkRunStatus();
    expect(c.currentRun!.runId, 'run_recovered_42');
    expect(c.currentRun!.sessionId, startsWith('saathi_'));
    expect(fixture.statusReads, 1);
    expect(c.currentRun!.snapshot.state, RunState.running);
    expect(fixture.posts, 1);

    fixture.runStatus = 'completed';
    fixture.runOutput = 'Build succeeded';
    await c.checkRunStatus();
    expect(c.runPending, isFalse);
    expect(c.current!.messages.map((m) => m.content),
        ['run my build', 'Build succeeded']);
    expect(fixture.posts, 1);
  });

  test('diverged or foreign-session history fails closed during receipt sync',
      () async {
    final fixture = SyncFixture();
    final c = await createController(fixture);
    addTearDown(c.dispose);

    expect(await c.send('new question'), isTrue);
    // Case 1: foreign session_id in response.
    fixture.overrideHistorySessionId = 'foreign_session';
    fixture.history = [
      {'id': 1, 'role': 'user', 'content': 'hello'},
      {'id': 2, 'role': 'assistant', 'content': 'Old reply'},
      {'id': 3, 'role': 'user', 'content': 'new question'},
      {'id': 4, 'role': 'assistant', 'content': 'Foreign answer'},
    ];
    await c.checkRunStatus();
    expect(c.runPending, isTrue);
    expect(c.current!.messages, hasLength(2));

    // Case 2: diverged prefix (existing local history does not match).
    fixture.overrideHistorySessionId = null;
    fixture.history = [
      {'id': 1, 'role': 'user', 'content': 'different earlier prompt'},
      {'id': 2, 'role': 'assistant', 'content': 'different earlier reply'},
      {'id': 3, 'role': 'user', 'content': 'new question'},
      {'id': 4, 'role': 'assistant', 'content': 'Diverged answer'},
    ];
    await c.checkRunStatus();
    expect(c.runPending, isTrue);
    expect(c.current!.messages, hasLength(2));
    expect(fixture.posts, 1);
  });

  testWidgets(
      'periodic refresh auto-syncs and manual Refresh recovers at 360px 2x',
      (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(360, 800);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final fixture = SyncFixture()..historyFails = true;
    late ChatController c;
    await t.runAsync(() async {
      c = await createController(fixture);
    });
    Future<void> flush() async {
      for (var i = 0; i < 8; i++) {
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
        await t.pump();
      }
    }

    await t.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(2),
          viewInsets: const EdgeInsets.only(bottom: 220),
        ),
        child: child!,
      ),
      home: ChatHome(controller: c),
    ));

    await t.runAsync(() => c.send('check my server'));
    await t.pump();
    await t.pump();
    expect(fixture.posts, 1);
    expect(find.text('Refresh').hitTestable(), findsOneWidget);
    expect(find.text('Reconnect'), findsNothing);
    expect(find.textContaining('without its reply ID'), findsNothing);
    expect(c.showPendingThinking, isTrue);
    final transcriptScroll = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    await t.scrollUntilVisible(find.byType(BusyThinking), 150,
        scrollable: transcriptScroll);
    expect(find.byType(BusyThinking), findsOneWidget);

    // Bind scheduler to widget clock and let bounded automatic retries run.
    c.pauseRuns(false);
    for (final seconds in [2, 4, 8]) {
      await t.pump(Duration(seconds: seconds));
      await flush();
    }
    expect(fixture.historyReads, 3);
    // Exhausted automatic sync stops polling.
    await t.pump(const Duration(seconds: 60));
    await flush();
    expect(fixture.historyReads, 3,
        reason: 'Exhausted sync must not poll forever');
    expect(c.showPendingThinking, isFalse);
    expect(find.byType(BusyThinking, skipOffstage: false), findsNothing);
    expect(c.runObservationProblem, contains('Tap Refresh'));
    expect(find.text('Refresh').hitTestable(), findsOneWidget);

    // Server now has the synced turn; tapping Refresh recovers without resending.
    fixture.historyFails = false;
    fixture.history = [
      ...fixture.history,
      {'id': 3, 'role': 'user', 'content': 'check my server'},
      {'id': 4, 'role': 'assistant', 'content': 'Recovered via Refresh'},
    ];
    await t.tap(find.text('Refresh'));
    await flush();
    expect(c.runPending, isFalse);
    await t.scrollUntilVisible(find.text('Recovered via Refresh'), 150,
        scrollable: transcriptScroll);
    expect(find.text('Recovered via Refresh'), findsOneWidget);
    expect(fixture.posts, 1);
    expect(t.takeException(), isNull);

    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  test('in-flight receipt sync is revoked on authority rotation or pause',
      () async {
    for (final mode in ['rotation', 'pause']) {
      final fixture = SyncFixture();
      final c = await createController(fixture);
      addTearDown(c.dispose);
      expect(await c.send('protected prompt'), isTrue);
      fixture.history = [
        ...fixture.history,
        {'id': 3, 'role': 'user', 'content': 'protected prompt'},
        {'id': 4, 'role': 'assistant', 'content': 'Must not commit'},
      ];
      final gate = fixture.historyGate = Completer<void>();
      final syncing = c.checkRunStatus();
      while (fixture.historyReads == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (mode == 'rotation') {
        c.connections[0] = {
          ...c.connections.single,
          'authorityEpoch': 'replaced',
        };
      } else {
        c.pauseRuns(true);
      }
      gate.complete();
      await syncing;
      expect(c.current!.messages, hasLength(2));
      expect(c.currentRun!.committed, isFalse);
      expect(fixture.posts, 1);
    }
  });
}
