import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/transcript_latest.dart';
import 'agent_runs_test.dart' show capabilities;

void main() {
  for (final invalid in ['foreign session', 'null', 'number', 'map']) {
    for (final width in [360.0, 390.0]) {
      testWidgets(
          'Runs $invalid exhausts visibly then resumes live checks at $width',
          (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(width, 900);
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        late ChatController c;
        var status = 'invalid';
        final requests = <String>[];
        var posts = 0, reads = 0, notifications = 0;
        await t.runAsync(() async {
          SharedPreferences.setMockInitialValues({});
          c = ChatController(
              SaathiStore(
                  preferences: await SharedPreferences.getInstance(),
                  secrets: MemorySecrets()),
              runClientFactory: (root, key) =>
                  RunClient(root, key, client: MockClient((r) async {
                    requests.add('${r.method} ${r.url.path}');
                    expectSync(r.url.origin, 'https://original.example');
                    if (r.url.path.endsWith('capabilities')) {
                      return http.Response(jsonEncode(capabilities), 200);
                    }
                    if (r.method == 'POST') {
                      posts++;
                      return http.Response(
                          '{"run_id":"original","status":"running"}', 202);
                    }
                    reads++;
                    expectSync(r.method, 'GET');
                    expectSync(r.url.path, '/v1/runs/original');
                    return http.Response(
                        jsonEncode({
                          'run_id': 'original',
                          'session_id': status == 'invalid' &&
                                  invalid == 'foreign session'
                              ? 'foreign'
                              : c.currentRun!.sessionId,
                          'status':
                              status == 'running' ? 'running' : 'completed',
                          if (status != 'running')
                            'output': status != 'invalid'
                                ? 'Recovered original answer'
                                : switch (invalid) {
                                    'null' => null,
                                    'number' => 7,
                                    'map' => <String, Object?>{},
                                    _ => 'Foreign answer must never land',
                                  },
                        }),
                        200);
                  })));
          await c.load();
          await c.addConnection({
            'id': 'original',
            'name': 'Original',
            'type': 'hermes',
            'url': 'https://original.example'
          }, 'fixture');
          await c.newSession(c.connections.single, 'model', '');
          c.onReplyReceived = (_) => notifications++;
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
                    viewInsets: const EdgeInsets.only(bottom: 220)),
                child: child!),
            home: ChatHome(controller: c)));
        await t.runAsync(() => c.send('original input'));
        await t.pump();
        expect(posts, 1);
        expect(reads, 1);
        expect(c.error, isNull);
        expect(find.byKey(const Key('chat-error')), findsNothing);
        expect(find.byType(BusyThinking), findsOneWidget);
        expect(c.runObservationProblem, 'Reconnecting to check your reply');
        expect(c.submit('held follower'), isTrue);
        await t.enterText(find.byKey(const Key('composer')), 'Newer draft');
        await t.pump();
        c.pauseRuns(false); // Bind the real scheduler to the widget clock.
        for (final seconds in [2, 4, 8]) {
          await t.pump(Duration(seconds: seconds));
          await flush();
        }
        expect(reads, 4,
            reason: 'busy=${c.busy} pending=${c.runPending} '
                'run=${c.currentRun?.data} problem=${c.runObservationProblem} '
                'error=${c.error} requests=$requests');
        await t.pump(const Duration(seconds: 60));
        expect(reads, 4, reason: 'exhausted observations cannot poll forever');
        expect(posts, 1);
        expect(c.current!.messages, isEmpty);
        expect(notifications, 0);
        expect(find.byType(BusyThinking), findsNothing);
        expect(c.runObservationProblem, contains('Use Check status'));
        final recovery = find.text(c.runObservationProblem!);
        await t.scrollUntilVisible(recovery, 100,
            scrollable: find.descendant(
                of: find.byKey(const Key('chat-feedback')),
                matching: find.byType(Scrollable)));
        await t.ensureVisible(recovery);
        await t.pump();
        // At 2x text the feedback paragraph can exceed its bounded viewport.
        // Its leading text must be reachable; its center may still be clipped.
        expect(recovery.hitTestable(at: Alignment.topCenter), findsOneWidget);
        expect(c.runPending, isTrue);
        expect(c.currentRun!.committed, isFalse);
        expect(c.canResumeQueue, isFalse);
        expect(c.outbox.single.text, 'held follower');
        final check = find.byWidgetPredicate((widget) =>
            widget is IconButton && widget.tooltip == 'Check status');
        expect(check, findsOneWidget);
        expect(t.widget<IconButton>(check).onPressed, isNotNull);
        expect(find.text('Newer draft'), findsOneWidget);

        // Successful manual observation of ongoing work must restart automatic
        // checking, not leave a permanently animated stale running snapshot.
        status = 'running';
        await t.tap(check);
        await flush();
        expect(reads, 5);
        expect(c.runObservationProblem, isNull);
        expect(c.showPendingThinking, isTrue);
        await t.pump(const Duration(milliseconds: 200));
        await t.scrollUntilVisible(find.byType(BusyThinking), 100,
            scrollable: find.descendant(
                of: find.byType(TranscriptLatest),
                matching: find.byType(Scrollable)));
        expect(find.byType(BusyThinking), findsOneWidget);
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(seconds: 2));
          await flush();
          expect(reads, 6 + i,
              reason: 'valid ongoing work keeps its existing poll owner live');
          expect(c.runPending, isTrue);
          expect(c.showPendingThinking, isTrue);
          expect(posts, 1);
        }
        // Correct settlement may release ordinary followers, but never a
        // deliberate pause. This also prevents the fixture admitting a new run.
        c.pauseQueue('Paused by you');
        status = 'completed';
        await t.pump(const Duration(seconds: 2));
        await flush();
        expect(reads, 11);
        expect(c.runPending, isFalse);
        expect(c.currentRun!.committed, isTrue);
        expect(c.current!.messages.map((m) => m.content),
            ['original input', 'Recovered original answer']);
        expect(notifications, 1);
        expect(c.outbox.single.text, 'held follower');
        expect(c.queueStatus, 'Paused by you');
        expect(find.byType(BusyThinking), findsNothing);
        expect(find.text('Newer draft'), findsOneWidget);
        await t.pump(const Duration(seconds: 60));
        expect(reads, 11);
        expect(posts, 1);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() async => c.dispose());
        await t.pump();
      });
    }
  }
}
