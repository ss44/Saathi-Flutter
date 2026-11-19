import 'dart:async';
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

import 'agent_runs_test.dart' show capabilities;
import 'pending_message_home_test.dart' show FlowFixture;

class DecisionFixture {
  DecisionFixture(this.clarify);
  final bool clarify;
  late ChatController c;
  bool pending = true, unavailable = false;
  String? settledStatus;
  Completer<void>? holdRead;
  final requests = <http.Request>[];
  int reads = 0;
  Iterable<http.Request> get submissions =>
      requests.where((r) => r.method == 'POST' && r.url.path == '/v1/runs');
  Iterable<http.Request> get decisions =>
      requests.where((r) => r.method == 'POST' && r.url.path != '/v1/runs');
  Map<String, dynamic> snapshot() => {
        'run_id': 'original',
        'session_id': c.currentRun!.sessionId,
        'admission_id': 'admission',
        'execution_generation': 3,
        'status':
            settledStatus ?? (clarify ? 'running' : 'waiting_for_approval'),
        'pending_controls': [
          if (pending)
            {
              'kind': clarify ? 'clarify' : 'approval',
              'prompt_id': 'prompt',
              'execution_generation': 3,
              'command': 'echo safe',
              'question': 'Which target?',
              'choices': clarify ? ['A', 'B'] : ['once', 'deny'],
            },
        ],
        if (settledStatus == 'completed') 'output': 'Original final answer',
      };

  Future<void> mount(WidgetTester t, double width) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 900);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      c = ChatController(
        SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets(),
        ),
        runClientFactory: (root, key) =>
            RunClient(root, key, client: MockClient((r) async {
          requests.add(r);
          expectSync(r.url.host, 'original.example');
          expectSync(r.headers['authorization'], 'Bearer fixture');
          expectSync(r.followRedirects, isFalse);
          if (r.url.path.endsWith('capabilities')) {
            return http.Response(
                jsonEncode({
                  'features': {
                    ...capabilities['features'] as Map,
                    'run_approval_response': true,
                  },
                  'endpoints': {
                    ...capabilities['endpoints'] as Map,
                    'run_approval': {
                      'method': 'POST',
                      'path': '/v1/runs/{run_id}/approval',
                    },
                  },
                }),
                200);
          }
          if (r.method == 'POST') {
            if (r.url.path == '/v1/runs') {
              return http.Response(
                  '{"run_id":"original","status":"started"}', 202);
            }
            expectSync(r.url.path,
                '/v1/runs/original/${clarify ? 'clarify' : 'approval'}');
            // A failed answer cannot resolve the outstanding user decision.
            return http.Response('{}', 503);
          }
          expectSync(r.method, 'GET');
          expectSync(r.url.path, '/v1/runs/original');
          reads++;
          await holdRead?.future;
          return unavailable
              ? http.Response('{}', 503)
              : http.Response(jsonEncode(snapshot()), 200);
        })),
      );
      await c.load();
      await c.addConnection({
        'id': 'original',
        'name': 'Original',
        'type': 'hermes',
        'url': 'https://original.example',
      }, 'fixture');
      await c.newSession(
          c.connections.single, 'model', 'original instructions');
    });
    await t.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(2),
          viewInsets: const EdgeInsets.only(bottom: 240),
        ),
        child: child!,
      ),
      home: ChatHome(controller: c),
    ));
    await t.runAsync(() => c.send('Original input'));
    await flush(t);
  }

  Future<void> flush(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump();
    }
  }

  void expectDecision() {
    expect(c.currentRun!.snapshot.state,
        clarify ? RunState.running : RunState.waitingForApproval);
    expect(c.currentRun!.snapshot.pendingControls.single['kind'],
        clarify ? 'clarify' : 'approval');
    expect(c.runPending, isTrue);
    expect(c.showPendingThinking, isFalse);
    expect(c.pendingStatus, 'Your decision is needed');
    expect(find.byType(BusyThinking), findsNothing);
    // With concrete controls, ChatHome uses the actionable decision label.
    expect(find.text(clarify ? 'Answer needed' : 'Review action').hitTestable(),
        findsOneWidget);
    expect(submissions, hasLength(1));
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async => c.dispose());
    await t.pump();
  }
}

void main() {
  for (final width in [360.0, 390.0]) {
    testWidgets(
        'approval without control details keeps its visible label at $width',
        (t) async {
      final f = FlowFixture()
        ..width = width
        ..scale = 2
        ..status = 'waiting_for_approval';
      await f.mount(t);
      f.admission.complete();
      await t.runAsync(() => f.c.send('Original input'));
      await t.pump();
      expect(
          find.text('Your decision is needed').hitTestable(), findsOneWidget);
      f.unavailable = true;
      await t.runAsync(() => f.c.checkRunStatus());
      await t.pump();
      expect(f.c.pendingStatus, 'Your decision is needed');
      expect(
          find.text('Your decision is needed').hitTestable(), findsOneWidget);
      expect(find.byType(BusyThinking), findsNothing);
      expect(find.text('Reconnecting to check your reply'), findsOneWidget);
      expect(find.byTooltip('Check status').hitTestable(), findsOneWidget);
      expect(f.posts, 1);
      await f.close(t);
    });
  }
  for (final clarify in [false, true]) {
    for (final width in [360.0, 390.0]) {
      testWidgets(
          '${clarify ? 'clarification' : 'approval'} retains decision across recovery, answer failure and foreground at $width',
          (t) async {
        final f = DecisionFixture(clarify);
        await f.mount(t, width);
        final session = f.c.current!;
        final source = f.c.connections.single;
        final op = f.c.currentRun!;
        final data = jsonEncode(op.data);
        final journalKey = 'run.v1.${session.id}';
        final journal =
            await t.runAsync(() => f.c.store.secrets.read(journalKey));
        expect(journal, isNotNull);
        f.expectDecision();
        expect(f.submissions.single.body, op.payload);
        expect(f.submissions.single.headers['Idempotency-Key'], op.key);

        f.unavailable = true;
        // Observe the in-flight manual read as well as its failed result.
        f.holdRead = Completer<void>();
        final checking = f.c.checkRunStatus();
        await f.flush(t);
        expect(f.c.busy, isTrue);
        f.expectDecision();
        f.holdRead!.complete();
        await f.flush(t);
        await checking;
        f.holdRead = null;
        f.expectDecision();
        expect(f.c.runObservationProblem, 'Reconnecting to check your reply');
        expect(find.text('Reconnecting to check your reply'), findsOneWidget);

        f.c.pauseRuns(false);
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(seconds: 8));
          await f.flush(t);
          f.expectDecision();
        }
        expect(f.reads, 5); // One valid GET, four failed observations.
        expect(f.c.runObservationProblem, contains('Use Check status'));
        final exhausted = f.requests.length;
        await t.pump(const Duration(seconds: 60));
        await f.flush(t);
        expect(f.requests, hasLength(exhausted));
        expect(f.decisions, isEmpty);
        expect(f.c.current, same(session));
        expect(f.c.connections.single, same(source));
        expect(f.c.currentRun, same(op));
        expect(jsonEncode(op.data), data);
        expect(await t.runAsync(() => f.c.store.secrets.read(journalKey)),
            journal);
        expect(session.messages, isEmpty);

        // The actual manual action restores observations, not a working claim.
        f.unavailable = false;
        await t.tap(find.byTooltip('Check status'));
        await f.flush(t);
        f.expectDecision();
        expect(f.c.runObservationProblem, isNull);
        final manualReads = f.reads;
        await t.pump(const Duration(seconds: 2));
        await f.flush(t);
        expect(f.reads, manualReads + 1);
        f.expectDecision();

        // Preserve the actual decision controls and exact non-inference POST.
        await t.tap(find.text(clarify ? 'Answer needed' : 'Review action'));
        await f.flush(t);
        await t.pump(const Duration(milliseconds: 300));
        if (clarify) {
          await t.tap(find.text('A'));
          await t.pump();
        }
        final answer =
            find.widgetWithText(FilledButton, clarify ? 'Send' : 'Allow once');
        await t.ensureVisible(answer);
        await t.tap(answer);
        await f.flush(t);
        expect(f.decisions, hasLength(1));
        expect(jsonDecode(f.decisions.single.body), {
          'request_id': 'prompt',
          'execution_generation': 3,
          if (clarify) 'answer': 'A' else 'choice': 'once',
        });
        expect(
            find.textContaining('Response was not confirmed'), findsOneWidget);
        expect(f.c.showPendingThinking, isFalse);
        await t.binding.handlePopRoute();
        await t.pump(const Duration(milliseconds: 300));
        await f.flush(t);
        f.expectDecision();

        f.unavailable = true;
        for (var i = 0; i < 7; i++) {
          await t.pump(const Duration(seconds: 8));
          await f.flush(t);
        }
        expect(f.c.runObservationProblem, contains('Use Check status'));
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          t.binding.handleAppLifecycleStateChanged(state);
          await t.pump();
        }
        final pausedRequests = f.requests.length;
        await t.pump(const Duration(seconds: 60));
        await f.flush(t);
        expect(f.requests, hasLength(pausedRequests));
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          t.binding.handleAppLifecycleStateChanged(state);
          await t.pump();
        }
        f.expectDecision();
        expect(f.c.runObservationProblem, 'Reconnecting to check your reply');
        await t.pump(const Duration(seconds: 2));
        await f.flush(t);
        f.expectDecision();
        expect(f.requests.length, greaterThan(pausedRequests));
        expect(f.decisions, hasLength(1));
        expect(await t.runAsync(() => f.c.store.secrets.read(journalKey)),
            journal);

        // Only an authoritative ongoing snapshot with no decision revives thinking.
        f.unavailable = false;
        f.pending = false;
        f.settledStatus = 'running';
        await t.tap(find.byTooltip('Check status'));
        await f.flush(t);
        expect(f.c.currentRun, same(op));
        expect(f.c.runObservationProblem, isNull);
        expect(f.c.showPendingThinking, isTrue);
        expect(f.c.pendingStatus, 'Working on your reply');
        await t.drag(find.byType(ListView).first, const Offset(0, -1600));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.byType(BusyThinking), findsOneWidget);
        f.settledStatus = 'completed';
        await t.pump(const Duration(seconds: 2));
        await f.flush(t);
        expect(op.committed, isTrue);
        expect(f.c.showPendingThinking, isFalse);
        expect(find.byType(BusyThinking), findsNothing);
        expect(session.messages.map((m) => m.content),
            ['Original input', 'Original final answer']);
        expect(f.c.current, same(session));
        expect(f.c.connections.single, same(source));
        expect(f.submissions, hasLength(1));
        expect(f.submissions.single.body, op.payload);
        expect(f.submissions.single.headers['Idempotency-Key'], op.key);
        expect(f.decisions, hasLength(1));
        expect(t.takeException(), isNull);
        await f.close(t);
      });
    }

    for (final status in ['completed', 'failed', 'cancelled', 'interrupted']) {
      testWidgets(
          '${clarify ? 'clarification' : 'approval'} failed observation then authoritative $status clears decision without thinking',
          (t) async {
        final f = DecisionFixture(clarify);
        await f.mount(t, 390);
        f.unavailable = true;
        await t.runAsync(() => f.c.checkRunStatus());
        await f.flush(t);
        f.expectDecision();
        f.unavailable = false;
        f.settledStatus = status;
        // Even retained controls on a terminal snapshot cannot revive a decision.
        await t.tap(find.byTooltip('Check status'));
        await f.flush(t);
        expect(f.c.currentRun!.snapshot.terminal, isTrue);
        expect(f.c.showPendingThinking, isFalse);
        expect(f.c.pendingStatus, isNot('Your decision is needed'));
        expect(find.byType(BusyThinking), findsNothing);
        expect(f.submissions, hasLength(1));
        expect(f.decisions, isEmpty);
        expect(t.takeException(), isNull);
        await f.close(t);
      });
    }
  }
}
