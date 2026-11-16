import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';

class RejectSecrets extends MemorySecrets {
  @override
  Future<void> write(String id, String value) async => throw StateError('disk');
}

Future<RunOperation> prepare(RunClient c, RunLedger l) => c.prepare(l,
    local: 'local', input: 'hello', model: 'm', instructions: '', history: []);
void main() {
  test(
      'unknown resolution uses exact current identity and refreshes 409 without resend',
      () async {
    var reads = 0, posts = 0;
    final c =
        RunClient('https://host', 'fixture', client: MockClient((r) async {
      if (r.method == 'POST') {
        posts++;
        expect(r.url.path, '/v1/runs/r/resolve-unknown');
        expect(jsonDecode(r.body),
            {'admission_id': 'adm', 'execution_generation': 7});
        return http.Response('{"error":{"code":"stale_generation"}}', 409);
      }
      reads++;
      return http.Response(
          jsonEncode({
            'run_id': 'r',
            'status': reads == 1 ? 'unknown' : 'interrupted',
            'admission_id': 'adm',
            'execution_generation': 7
          }),
          200);
    }));
    c.capabilities = {
      'features': {'run_unknown_resolution': true},
      'endpoints': {
        'run_unknown_resolution': {
          'method': 'POST',
          'path': '/v1/runs/{run_id}/resolve-unknown'
        }
      }
    };
    final l = RunLedger(MemorySecrets());
    final op = await prepare(c, l);
    op.data['run'] = 'r';
    await expectLater(c.resolveUnknown(op, l, acknowledgedSideEffects: true),
        throwsStateError);
    expect(reads, 2);
    expect(posts, 1);
    expect(op.snapshot.state, RunState.interrupted);
  });
  test('untrusted snapshot fields have safe typed getters', () {
    final s = RunSnapshot(
        {'status': 1, 'run_id': [], 'admission_id': {}, 'pending_controls': 4});
    expect(s.status, 'unknown');
    expect(s.runId, isNull);
    expect(s.admissionId, isNull);
    expect(s.pendingControls, isEmpty);
  });
  test('malformed ledger is rejected before typed getters or overwrite',
      () async {
    final secrets = MemorySecrets();
    final ledger = RunLedger(secrets);
    for (final raw in ['{}', '{"key":12}', '"text"', 'x' * (256 * 1024 + 1)]) {
      await secrets.write('run.v1.local', raw);
      await expectLater(ledger.load('local'), throwsFormatException);
      expect(await secrets.read('run.v1.local'), raw);
    }
  });
  test('journal reload preserves bytes/key and rejects changed authority',
      () async {
    final ledger = RunLedger(MemorySecrets());
    final c = RunClient('https://host/p/work/v1', 'fixture');
    final op = await prepare(c, ledger);
    final restored = (await ledger.load('local'))!;
    expect(restored.payload, op.payload);
    expect(restored.key, op.key);
    expect(() => RunClient('https://host/p/work', 'rotated').bind(restored),
        throwsStateError);
    expect(() => RunClient('https://other/p/work', 'fixture').bind(restored),
        throwsStateError);
    expect(() => RunClient('https://host/p/other', 'fixture').bind(restored),
        throwsStateError);
    c.close();
  });
  test('secure storage failure before admission makes zero HTTP calls',
      () async {
    var calls = 0;
    final c =
        RunClient('https://host', 'fixture', client: MockClient((r) async {
      calls++;
      return http.Response('{}', 202);
    }));
    await expectLater(prepare(c, RunLedger(RejectSecrets())), throwsStateError);
    expect(calls, 0);
  });
  test('status transport loss resumes by GET only, duplicate final is stable',
      () async {
    final methods = <String>[];
    var gets = 0;
    final c =
        RunClient('https://host', 'fixture', client: MockClient((r) async {
      methods.add(r.method);
      if (r.method == 'POST') {
        return http.Response('{"run_id":"run_1","status":"started"}', 202);
      }
      if (gets++ == 0) throw http.ClientException('drop');
      return http.Response(
          '{"run_id":"run_1","status":"completed","output":"done"}', 200);
    }));
    final l = RunLedger(MemorySecrets());
    final op = await prepare(c, l);
    await c.submit(op, l);
    await expectLater(c.status(op, l), throwsA(isA<http.ClientException>()));
    final restored = (await l.load('local'))!;
    expect((await c.status(restored, l)).output, 'done');
    await c.status(restored, l);
    expect(methods, ['POST', 'GET', 'GET', 'GET']);
  });
  test('queued 503 is accepted and draining 503 never creates a new identity',
      () async {
    for (final queued in [true, false]) {
      final c = RunClient('https://host', 'fixture',
          client: MockClient((r) async => http.Response(
              jsonEncode({
                'error': {
                  'code': queued ? 'admission_queued' : 'runtime_draining'
                }
              }),
              503,
              headers: queued ? {'x-should-retry': 'false'} : {})));
      final l = RunLedger(MemorySecrets());
      final op = await prepare(c, l);
      final key = op.key;
      if (queued) {
        await c.submit(op, l);
        expect(op.snapshot.state, RunState.queued);
      } else {
        await expectLater(c.submit(op, l), throwsStateError);
      }
      expect((await l.load('local'))!.key, key);
    }
  });
  test('expired replay cannot submit', () async {
    var posts = 0;
    final c =
        RunClient('https://host', 'fixture', client: MockClient((r) async {
      posts++;
      return http.Response('{}', 202);
    }));
    final l = RunLedger(MemorySecrets());
    final op = await prepare(c, l);
    op.data['created'] =
        DateTime.now().subtract(const Duration(hours: 25)).toIso8601String();
    await expectLater(c.submit(op, l), throwsStateError);
    expect(posts, 0);
  });
  test('canonical capability metadata cannot authorize arbitrary URLs',
      () async {
    final c = RunClient('https://host', 'fixture',
        client: MockClient((r) async => http.Response(
            jsonEncode({
              'features': {
                'run_submission': true,
                'run_status': true,
                'runs_idempotency': {}
              },
              'endpoints': {
                'runs': {'method': 'POST', 'path': 'https://evil/v1/runs'},
                'run_status': {'method': 'GET', 'path': '/v1/runs/{run_id}'}
              }
            }),
            200)));
    expect(await c.discover(), false);
  });
}
