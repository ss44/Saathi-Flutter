import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

import 'agent_runs_test.dart' show capabilities;

const _invalidObservations = <String, Map<String, dynamic>>{
  'missing': {},
  'empty': {'status': ''},
  'whitespace': {'status': ' '},
  'null': {'status': null},
  'number': {'status': 42},
  'object': {
    'status': {'state': 'running'}
  },
  'unrecognized': {'status': 'not_a_run_state'},
  'foreign run': {'run_id': 'foreign', 'status': 'running'},
  'foreign session': {'session_id': 'foreign', 'status': 'running'},
};

void main() {
  for (final entry in _invalidObservations.entries) {
    testWidgets(
        '${entry.key} observation preserves identity and exhausts; manual read resumes same poll owner',
        (t) async {
      late ChatController c;
      var invalid = false;
      var complete = false;
      var reads = 0;
      var requests = 0;
      final posts = <http.Request>[];
      await t.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        c = ChatController(
            SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: MemorySecrets(),
            ),
            runClientFactory: (root, key) =>
                RunClient(root, key, client: MockClient((r) async {
                  requests++;
                  expectSync(r.url.host, 'original.example');
                  expectSync(r.headers['authorization'], 'Bearer fixture');
                  if (r.url.path.endsWith('capabilities')) {
                    return http.Response(jsonEncode(capabilities), 200);
                  }
                  if (r.method == 'POST') {
                    posts.add(r);
                    return http.Response(
                        '{"run_id":"original","status":"started"}', 202);
                  }
                  reads++;
                  expectSync(r.method, 'GET');
                  expectSync(r.url.path, '/v1/runs/original');
                  return http.Response(
                      jsonEncode({
                        'run_id': 'original',
                        'session_id': c.currentRun!.sessionId,
                        if (!invalid)
                          'status': complete ? 'completed' : 'running',
                        if (invalid) ...entry.value,
                        if (complete) 'output': 'Original final answer',
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
        await c.newSession(
            c.connections.single, 'model', 'captured instructions');
        c.current!.messages.add(ChatMessage(
            role: 'user', content: 'Private earlier history', id: 'earlier'));
        await c.send('input');
      });
      addTearDown(c.dispose);
      final session = c.current!;
      final operation = c.currentRun!;
      final operationData = jsonEncode(operation.data);
      final history =
          jsonEncode(session.messages.map((m) => m.toJson()).toList());
      final journalKey = 'run.v1.${session.id}';
      final raw = await t.runAsync(() => c.store.secrets.read(journalKey));
      expect(raw, isNotNull);
      expect(c.showPendingThinking, isTrue);
      expect(operation.snapshot.state, RunState.running);
      expect(posts, hasLength(1));
      expect(jsonDecode(posts.single.body)['conversation_history'], isNotEmpty);
      expect(posts.single.body, operation.payload);
      expect(posts.single.headers['Idempotency-Key'], operation.key);
      invalid = true;
      // Move the existing scheduler into this test's fake-clock zone.
      c.pauseRuns(false);
      Future<void> flush() async {
        for (var i = 0; i < 8; i++) {
          await t.runAsync(() => Future<void>.delayed(Duration.zero));
          await t.pump();
        }
      }

      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(seconds: 8));
        await flush();
      }
      expect(reads, 5,
          reason: 'One valid read followed by four failed observations');
      expect(c.showPendingThinking, isFalse);
      expect(c.pendingStatus, 'Check your message’s status');
      expect(c.runObservationProblem, contains('Use Check status'));
      expect(c.current, same(session));
      expect(c.currentRun, same(operation));
      expect(jsonEncode(operation.data), operationData);
      expect(jsonEncode(session.messages.map((m) => m.toJson()).toList()),
          history);
      expect(await t.runAsync(() => c.store.secrets.read(journalKey)), raw);
      final exhaustedRequests = requests;
      await t.pump(const Duration(seconds: 60));
      await flush();
      expect(requests, exhaustedRequests,
          reason: 'No status or discovery after exhaustion');
      invalid = false;
      // A manual valid ongoing read restores the same automatic poll owner.
      final checking = c.checkRunStatus();
      await flush();
      await checking;
      expect(c.runObservationProblem, isNull);
      expect(c.showPendingThinking, isTrue);
      expect(c.currentRun, same(operation));
      expect(operation.runId, 'original');
      final resumedReads = reads;
      await t.pump(const Duration(seconds: 2));
      await flush();
      expect(reads, resumedReads + 1);
      complete = true;
      await t.pump(const Duration(seconds: 2));
      await flush();
      expect(c.showPendingThinking, isFalse);
      expect(operation.committed, isTrue);
      expect(
          session.messages.where((m) => m.content == 'Original final answer'),
          hasLength(1));
      expect(session.messages.where((m) => m.id == 'input-${operation.key}'),
          hasLength(1));
      expect(session.messages.first.content, 'Private earlier history');
      expect(c.current, same(session));
      expect(posts, hasLength(1));
      expect(posts.single.body, operation.payload);
      expect(posts.single.headers['Idempotency-Key'], operation.key);
      final settledRequests = requests;
      await t.pump(const Duration(seconds: 60));
      await flush();
      expect(requests, settledRequests);
    });
  }

  // The installed official Runs projection and legacy API both use these states.
  // 'started' is the documented admission alias for running; explicit 'unknown'
  // is a valid no-replay observation, not malformed/missing lifecycle data.
  for (final status in [
    'unknown',
    'queued',
    'started',
    'running',
    'stopping',
    'waiting_for_approval',
    'completed',
    'failed',
    'cancelled',
    'interrupted'
  ]) {
    test('recognized $status status remains an authoritative observation',
        () async {
      final secrets = MemorySecrets();
      final ledger = RunLedger(secrets);
      var posts = 0;
      final client = RunClient('https://original.example', 'fixture',
          client: MockClient((r) async {
        if (r.method == 'POST') {
          posts++;
          return http.Response('{"run_id":"original","status":"started"}', 202);
        }
        return http.Response(
            jsonEncode({
              'run_id': 'original',
              'session_id': 'session',
              'status': status,
              if (status == 'completed') 'output': 'answer'
            }),
            200);
      }));
      addTearDown(client.close);
      final op = await client.prepare(ledger,
          local: 'local',
          existingSessionId: 'session',
          input: 'input',
          model: 'model',
          instructions: '',
          history: []);
      await client.submit(op, ledger);
      final originalKey = op.key;
      final originalPayload = op.payload;
      final snapshot = await client.status(op, ledger);
      expect(snapshot.status, status);
      expect(snapshot.state, isNot(RunState.unrecognized));
      expect((await ledger.load('local'))!.snapshot.data, snapshot.data);
      expect(op.key, originalKey);
      expect(op.payload, originalPayload);
      expect(op.sessionId, 'session');
      expect(op.runId, 'original');
      expect(posts, 1);
    });
  }

  testWidgets(
      'explicit unknown stops automatically without replay or a fabricated failed-read budget',
      (t) async {
    late ChatController c;
    var reads = 0;
    var posts = 0;
    await t.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      c = ChatController(
          SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: MemorySecrets()),
          runClientFactory: (root, key) =>
              RunClient(root, key, client: MockClient((r) async {
                if (r.url.path.endsWith('capabilities')) {
                  return http.Response(jsonEncode(capabilities), 200);
                }
                if (r.method == 'POST') {
                  posts++;
                  return http.Response(
                      '{"run_id":"original","status":"started"}', 202);
                }
                reads++;
                return http.Response(
                    '{"run_id":"original","status":"unknown","admission_id":"admission","execution_generation":4}',
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
      await c.send('input');
    });
    c.pauseRuns(false);
    await t.pump(const Duration(seconds: 60));
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(c.currentRun!.snapshot.state, RunState.unknown);
    expect(c.currentRun!.snapshot.admissionId, 'admission');
    expect(c.showPendingThinking, isFalse);
    expect(c.runObservationProblem, isNull);
    expect(c.pendingStatus, 'Check your message’s status');
    expect(c.runPending, isTrue);
    expect(c.current!.messages, isEmpty);
    expect(reads, 1);
    expect(posts, 1);
    c.dispose();
  });
}
