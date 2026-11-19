import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'agent_runs_test.dart' show capabilities;

class FlowFixture {
  late ChatController c;
  late Completer<void> admission;
  Completer<void>? discovery;
  bool lostAck = false, unavailable = false;
  String status = 'queued';
  int posts = 0, reads = 0;
  double width = 390, scale = 1;
  bool reduced = false;
  Future<void> mount(WidgetTester t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 800);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.runAsync(() async {
      admission = Completer<void>();
      SharedPreferences.setMockInitialValues({});
      c = ChatController(
          SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: MemorySecrets()),
          runClientFactory: (root, key) =>
              RunClient(root, key, client: MockClient((r) async {
                if (r.url.path.endsWith('capabilities')) {
                  await discovery?.future;
                  return http.Response(jsonEncode(capabilities), 200);
                }
                if (r.method == 'POST') {
                  posts++;
                  await admission.future;
                  if (lostAck) throw const SocketException('lost response');
                  return http.Response(
                      '{"run_id":"original","status":"queued"}', 202);
                }
                reads++;
                if (unavailable) return http.Response('{}', 503);
                return http.Response(
                    jsonEncode({
                      'run_id': 'original',
                      'status': status,
                      if (status == 'completed') 'output': 'Final answer',
                    }),
                    200);
              })));
      await c.load();
      await c.addConnection({
        'id': 'h',
        'name': 'Hermes',
        'type': 'hermes',
        'url': 'https://host'
      }, 'fixture');
      await c.newSession(c.connections.single, 'model', '');
    });
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduced,
                viewInsets: const EdgeInsets.only(bottom: 240)),
            child: child!),
        home: ChatHome(controller: c)));
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      c.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    await t.pump();
  }
}

void main() {
  testWidgets('large text reduced animation pending state disposes cleanly',
      (t) async {
    final f = FlowFixture()
      ..width = 360
      ..scale = 2
      ..reduced = true;
    await f.mount(t);
    late Future<bool> sending;
    await t.runAsync(() async {
      sending = f.c.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
    await t.pump();
    expect(find.byType(BusyThinking), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final quip = t.widget<Text>(find.byKey(const Key('thinking-quip'))).data;
    await t.pump(const Duration(seconds: 8));
    expect(t.widget<Text>(find.byKey(const Key('thinking-quip'))).data, quip);
    expect(t.takeException(), isNull);
    await f.close(t);
    f.admission.complete();
    await t.runAsync(() => sending);
    await t.pump(const Duration(seconds: 20));
    expect(find.byType(BusyThinking), findsNothing);
    expect(f.posts, 1);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'delayed admission shows thinking then truthful activity and answer',
      (t) async {
    final f = FlowFixture();
    await f.mount(t);
    final scopes = <ScopedRunSnapshot>[];
    final subscription = f.c.scopedRunSnapshots.listen(scopes.add);
    late Future<bool> sending;
    await t.runAsync(() async {
      sending = f.c.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
    await t.pump();
    expect(find.byType(BusyThinking), findsOneWidget);
    expect(find.text('Sending your message'), findsWidgets);
    expect(find.byKey(const Key('chat-error')), findsNothing);
    f.admission.complete();
    await t.runAsync(() => sending);
    await t.pump();
    expect(find.byType(BusyThinking), findsOneWidget);
    expect(find.text('Waiting for its turn'), findsWidgets);
    f.status = 'running';
    await t.runAsync(() => f.c.checkRunStatus());

    await t.pump();
    expect(find.text('Working on your reply'), findsWidgets);
    f.c.observeRunEvent(scopes.last,
        {'event': 'tool.started', 'run_id': 'original', 'tool': 'search'},
        cursor: '1');
    await t.pump();
    expect(find.text('Using search'), findsOneWidget);

    f.c.observeRunEvent(scopes.last,
        {'event': 'tool.completed', 'run_id': 'original', 'tool': 'search'},
        cursor: '2');
    await t.pump();
    expect(find.text('Finished search'), findsOneWidget);

    f.c.observeRunEvent(
        scopes.last,
        {
          'event': 'reasoning.available',
          'run_id': 'original',
          'text': 'PRIVATE'
        },
        cursor: '3');
    await t.pump();
    expect(find.textContaining('PRIVATE'), findsNothing);

    f.c.observeRunEvent(
        scopes.last,
        {
          'event': 'message.delta',
          'run_id': 'original',
          'delta': 'Partial answer'
        },
        cursor: '4');
    await t.pump();
    expect(find.byType(BusyThinking), findsNothing);
    f.status = 'completed';
    await t.runAsync(() => f.c.checkRunStatus());
    await t.pump();
    expect(find.byType(BusyThinking), findsNothing);
    expect(
        f.c.current!.messages.map((m) => m.content), ['hello', 'Final answer']);
    expect(f.posts, 1);
    // The broadcast stream was created in runAsync. Cancel there too: awaiting
    // its real-zone future in fake-async strands the next pump during unmount.
    await t.runAsync(subscription.cancel);
    await f.close(t);
  });

  testWidgets('lost HTTP acknowledgement never resends even on status action',
      (t) async {
    final f = FlowFixture()..lostAck = true;
    await f.mount(t);
    late Future<bool> sending;
    await t.runAsync(() async {
      sending = f.c.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
    await t.pump();
    expect(find.byType(BusyThinking), findsOneWidget);
    f.admission.complete();
    await t.runAsync(() => sending);
    await t.pump();
    expect(find.byKey(const Key('chat-error')), findsNothing);
    expect(find.byType(BusyThinking), findsNothing);
    await t.runAsync(() => f.c.checkRunStatus());
    await t.pump(const Duration(seconds: 30));
    expect(f.posts, 1);
    expect(f.reads, 0);
    expect(f.c.runPending, isTrue);
    await f.close(t);
  });

  testWidgets(
      'status recovery is bounded and manual retry can recover completion',
      (t) async {
    final f = FlowFixture()..unavailable = true;
    await f.mount(t);
    f.admission.complete();
    await t.runAsync(() => f.c.send('hello'));
    await t.pump();
    expect(find.byKey(const Key('chat-error')), findsNothing);
    expect(find.byType(BusyThinking), findsOneWidget);
    expect(f.c.pendingStatus, 'Reconnecting to check your reply');
    f.c.pauseRuns(false); // Bind the existing scheduler to this test's clock.
    for (final seconds in [2, 4, 8]) {
      await t.pump(Duration(seconds: seconds));
      await t.pump();
    }
    expect(f.reads, 4);
    await t.pump(const Duration(seconds: 60));
    expect(f.reads, 4);
    expect(find.byType(BusyThinking), findsNothing);
    expect(f.c.runObservationProblem, contains('Use Check status'));
    f.unavailable = false;
    f.status = 'completed';
    await t.runAsync(() => f.c.checkRunStatus());
    await t.pump();
    expect(f.c.current!.messages.last.content, 'Final answer');
    expect(f.posts, 1);
    await f.close(t);
  });

  testWidgets('confirmed failure stops thinking and keeps followers paused',
      (t) async {
    final f = FlowFixture()..status = 'failed';
    await f.mount(t);
    late Future<bool> sending;
    await t.runAsync(() async {
      sending = f.c.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
    expect(f.c.submit('follower'), isTrue);
    f.admission.complete();
    await t.runAsync(() => sending);
    await t.pump();
    expect(find.byType(BusyThinking), findsNothing);
    expect(f.c.error,
        'The server could not finish this reply. Prior work may have had side effects.');
    expect(f.c.queueStatus, isNotNull);
    expect(f.posts, 1);
    await f.close(t);
  });
}
