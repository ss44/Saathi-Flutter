import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';

Future<RunOperation> prepare(RunClient c, RunLedger l,
        {RunOperation? previous}) =>
    c.prepare(l,
        local: 'local',
        input: 'hello',
        model: 'm',
        instructions: '',
        history: [],
        previous: previous);

class HeldSecrets extends MemorySecrets {
  Completer<void>? entered;
  Completer<void>? release;
  bool fail = false;
  @override
  Future<void> write(String id, String value) async {
    if (fail) throw StateError('disk');
    if (entered != null) {
      entered!.complete();
      await release!.future;
      entered = null;
    }
    await super.write(id, value);
  }
}

void main() {
  test('persisted operation cannot mutate its local identity into a new slot',
      () async {
    final l = RunLedger(MemorySecrets());
    final c = RunClient('https://host', 'fixture');
    final op = await prepare(c, l);
    op.data['local'] = 'other';
    await expectLater(l.save(op), throwsStateError);
    expect(await l.load('other'), isNull);
  });
  test('malformed network snapshot is rejected without replacing journal',
      () async {
    final l = RunLedger(MemorySecrets());
    final c = RunClient('https://host', 'fixture',
        client: MockClient((r) async => http.Response(
            '{"run_id":"r","status":"completed","output":[]}', 200)));
    final op = await prepare(c, l);
    op.data['run'] = 'r';
    await l.save(op);
    await expectLater(c.status(op, l), throwsFormatException);
    expect((await l.load('local'))!.snapshot.terminal, false);
  });
  test('stale queued writer is rechecked after shared-store lock and read',
      () async {
    final secrets = HeldSecrets();
    final l = RunLedger(secrets);
    final c = RunClient('https://host', 'fixture');
    final op = await prepare(c, l);
    secrets.entered = Completer<void>();
    secrets.release = Completer<void>();
    final first = l.save(op);
    await secrets.entered!.future;
    var current = true;
    final queued = RunLedger(secrets).save(op, isCurrent: () => current);
    final rejected = expectLater(queued, throwsStateError);
    current = false;
    secrets.release!.complete();
    await first;
    await rejected;
  });
  test(
      'nested malformed schema and invalid identities fail closed on load and save',
      () async {
    final secrets = MemorySecrets();
    final l = RunLedger(secrets);
    final c = RunClient('https://host', 'fixture');
    final op = await prepare(c, l);
    final original = jsonEncode(op.data);
    final mutations = <Map<String, dynamic>>[
      {'key': ' '},
      {'key': 'not-a-key'},
      {'session': ' '},
      {'run': '../x'},
      {'created': 'yesterday'},
      {'created': '2026-99-99T00:00:00Z'},
      {'origin': ' '},
      {'attempted': 'true'},
      {'committed': 1},
      {'alertClaimed': []},
      {
        'snapshot': {'output': []}
      },
      {
        'snapshot': {
          'status': 'completed',
          'pending_controls': [4]
        }
      },
      {
        'snapshot': {'execution_generation': '1'}
      },
    ];
    for (final mutation in mutations) {
      final invalid = {...op.data, ...mutation};
      await secrets.write('run.v1.local', jsonEncode(invalid));
      await expectLater(l.load('local'), throwsFormatException);
      await secrets.write('run.v1.local', original);
      await expectLater(l.save(RunOperation(invalid)), throwsA(anything));
      expect(await secrets.read('run.v1.local'), original);
    }
  });
  test('malformed nested capabilities cannot authorize submission', () async {
    for (final value in [
      [],
      'bad',
      {'runs': []}
    ]) {
      final c = RunClient('https://host', 'fixture',
          client: MockClient((r) async => http.Response(
              jsonEncode({'features': value, 'endpoints': value}), 200)));
      expect(await c.discover(), false);
    }
  });
  test(
      'lost journal after 202 reloads and explicitly reconnects exact key and bytes',
      () async {
    final secrets = HeldSecrets();
    final l = RunLedger(secrets);
    final requests = <(String, String)>[];
    final c =
        RunClient('https://host', 'fixture', client: MockClient((r) async {
      requests.add((
        r.headers['Idempotency-Key'] ?? r.headers['idempotency-key']!,
        r.body
      ));
      secrets.fail = requests.length == 1;
      return http.Response('{"run_id":"r","status":"started"}', 202);
    }));
    final op = await prepare(c, l);
    // The stored body is deliberately not canonical JSON.
    op.data['payload'] = op.payload; // no synthesis on reconnect
    await expectLater(c.submit(op, l), throwsStateError);
    secrets.fail = false;
    final restored = (await RunLedger(secrets).load('local'))!;
    expect(restored.runId, isNull);
    expect(requests.length, 1); // reload does not replay
    await c.submit(restored, l);
    expect(requests[1], requests[0]);
    expect(restored.key, op.key);
  });
  test(
      'replacement requires exact durable terminal predecessor; old copies cannot clobber it',
      () async {
    final l = RunLedger(MemorySecrets());
    final c = RunClient('https://host', 'fixture');
    final op = await prepare(c, l);
    await expectLater(prepare(c, l, previous: op), throwsStateError);
    op.data['snapshot'] = {'status': 'completed', 'output': 'actual'};
    op.data['committed'] = true;
    // Memory-only final is not a durable predecessor.
    await expectLater(prepare(c, l, previous: op), throwsStateError);
    await l.save(op);
    op.data['journalDirty'] = true;
    await expectLater(prepare(c, l, previous: op), throwsStateError);
    op.data.remove('journalDirty');
    final next = await prepare(c, l, previous: op);
    await expectLater(l.save(op), throwsStateError);
    expect((await l.load('local'))!.key, next.key);
  });
  test(
      'independent stale copy cannot roll back final output or durable markers',
      () async {
    final l = RunLedger(MemorySecrets());
    final c = RunClient('https://host', 'fixture');
    final op = await prepare(c, l);
    final stale = (await l.load('local'))!;
    op.data['snapshot'] = {'status': 'completed', 'output': 'actual'};
    op.data['committed'] = true;
    op.data['alertClaimed'] = true;
    await l.save(op);
    await l.save(stale);
    final saved = (await l.load('local'))!;
    expect(saved.snapshot.output, 'actual');
    expect(saved.committed, true);
    expect(saved.data['alertClaimed'], true);
    expect(stale.snapshot.output, 'actual');
  });
}
