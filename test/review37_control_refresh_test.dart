import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

import 'agent_runs_test.dart' show capabilities;

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

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async => c.dispose());
    await t.pump();
  }
}

void main() {
  for (final clarify in [false, true]) {
    testWidgets(
        'independent common: valid control-sheet recovery restarts original completion; clarify=$clarify',
        (t) async {
      final f = DecisionFixture(clarify);
      await f.mount(t, 360);
      final op = f.c.currentRun!;
      final session = f.c.current!;
      f.c.pauseRuns(false);
      f.unavailable = true;
      for (var i = 0; i < 4; i++) {
        await t.runAsync(() => f.c.checkRunStatus());
        await f.flush(t);
      }
      expect(f.reads, 5);
      expect(f.c.runObservationProblem, isNotNull);
      expect(op.snapshot.pendingControls, isNotEmpty);
      expect(f.submissions, hasLength(1));
      f.unavailable = false;
      f.pending = false;
      f.settledStatus = 'running';
      await t.tap(find.text(clarify ? 'Answer needed' : 'Review action'));
      await f.flush(t);
      await t.pump(const Duration(milliseconds: 300));
      expect(f.reads, greaterThan(5));
      expect(f.c.currentRun, same(op));
      expect(op.snapshot.state, RunState.running);
      expect(op.snapshot.pendingControls, isEmpty);
      await t.binding.handlePopRoute();
      await t.pump(const Duration(milliseconds: 300));
      await f.flush(t);
      final reads = f.reads;
      f.settledStatus = 'completed';
      await t.pump(const Duration(seconds: 2));
      await f.flush(t);
      final automaticReads = f.reads;
      final committed = op.committed;
      final messages = session.messages.map((m) => m.content).toList();
      expect(f.submissions, hasLength(1));
      expect(f.decisions, isEmpty);
      expect(f.c.current, same(session));
      expect(t.takeException(), isNull);
      await f.close(t);
      expect(automaticReads, reads + 1,
          reason:
              'A fresh valid original-run observation must resume automatic completion');
      expect(committed, isTrue);
      expect(messages, ['Original input', 'Original final answer']);
    });
  }
}
