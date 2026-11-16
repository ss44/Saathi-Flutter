import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'agent_run_hardening_test.dart' show FailingJournal, setup;
import 'agent_runs_test.dart' show capabilities;

class DelayedSecrets extends FailingJournal {
  Completer<void>? entered, release;
  @override
  Future<String?> read(String id) async {
    if (id == 'h' && release != null) {
      entered!.complete();
      await release!.future;
    }
    return super.read(id);
  }
}

void invalidate(ChatController c, String kind) {
  switch (kind) {
    case 'pause':
      c.pauseRuns(true);
    case 'source removal':
      c.connections.clear();
    case 'source replacement':
      c.connections[0] = {...c.connections[0]};
    case 'session removal':
      c.sessions.clear();
    case 'session replacement':
      final s = c.current!;
      c.sessions[0] =
          ChatSession(id: s.id, connectionId: s.connectionId, model: s.model);
    case 'dispose':
      c.dispose();
  }
}

class ReconcileSecrets extends DelayedSecrets {
  Completer<void>? writeEntered, writeRelease;
  bool failCommit = false, delayCommit = false;
  int writes = 0;
  @override
  Future<void> write(String id, String value) async {
    if (id.startsWith('run.v1.')) {
      writes++;
      final data = jsonDecode(value) as Map;
      if (failCommit && data['committed'] == true) throw StateError('commit');
      if (writeRelease != null &&
          (delayCommit
              ? data['committed'] == true
              : data['alertClaimed'] == true)) {
        writeEntered!.complete();
        await writeRelease!.future;
        writeRelease = null;
      }
    }
    await super.write(id, value);
  }
}

http.Response answer(http.Request r) {
  if (r.url.path.endsWith('capabilities')) {
    return http.Response(jsonEncode(capabilities), 200);
  }
  if (r.method == 'POST') {
    return http.Response('{"run_id":"r","status":"started"}', 202);
  }
  return http.Response(
      '{"run_id":"r","status":"completed","output":"actual"}', 200);
}

class DelayedHistory extends SaathiStore {
  DelayedHistory(SaathiStore source)
      : super(preferences: source.preferences, secrets: source.secrets);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    entered.complete();
    await release.future;
    await super.saveChats(chats);
  }
}

void main() {
  for (final kind in [
    'pause',
    'source removal',
    'source replacement',
    'session removal',
    'session replacement',
    'dispose'
  ]) {
    test('$kind during history save prevents terminal journal commit',
        () async {
      final secrets = ReconcileSecrets();
      final initial = await setup(secrets, (r) async => answer(r));
      final store = DelayedHistory(initial.store);
      initial.dispose();
      final c = ChatController(store,
          runClientFactory: (root, key) =>
              RunClient(root, key, client: MockClient((r) async => answer(r))));
      await c.load();
      final session = c.current!;
      final pending = c.send('original');
      await store.entered.future;
      final before = secrets.writes;
      invalidate(c, kind);
      store.release.complete();
      await pending;
      expect(secrets.writes, before);
      expect(c.runs[session.id]!.committed, false);
      if (kind != 'dispose') c.dispose();
    });
  }
  test('lost post-admission journal write restarts with exact key and body',
      () async {
    final secrets = ReconcileSecrets();
    final keys = <String>[], bodies = <String>[];
    Future<http.Response> handler(http.Request r) async {
      if (r.method == 'POST') {
        keys.add(r.headers['Idempotency-Key']!);
        bodies.add(r.body);
        if (keys.length == 1) secrets.fail = true;
      }
      return answer(r);
    }

    final c = await setup(secrets, handler);
    await c.send('original');
    c.dispose();
    secrets.fail = false;
    final restored = ChatController(c.store,
        runClientFactory: (root, key) =>
            RunClient(root, key, client: MockClient(handler)));
    await restored.load();
    expect(await restored.send('new work'), false);
    await restored.checkRunStatus();
    expect(keys.length, 2);
    expect(keys.toSet().length, 1);
    expect(bodies.toSet().length, 1);
    expect(restored.current!.messages.map((m) => m.content),
        ['original', 'actual']);
    await restored.checkRunStatus();
    expect(restored.current!.messages.length, 2);
    restored.dispose();
  });
  test(
      'scoped snapshots retain immutable original authority and revoke on replacement',
      () async {
    final c = await setup(ReconcileSecrets(), (r) async => answer(r));
    final received = <ScopedRunSnapshot>[];
    final subscription = c.scopedRunSnapshots.listen(received.add);
    await c.send('original');
    await Future<void>.delayed(Duration.zero);
    final envelope = received.single;
    expect(envelope.localChatId, c.current!.id);
    expect(envelope.connectionId, 'h');
    expect(envelope.operationKey, c.currentRun!.key);
    expect(envelope.originalAuthority['origin'], 'https://host');
    expect(envelope.snapshot.output, 'actual');
    expect(envelope.isCurrent(), true);
    expect(() => envelope.originalAuthority['origin'] = 'elsewhere',
        throwsUnsupportedError);
    c.connections[0] = {...c.connections[0]};
    expect(envelope.isCurrent(), false);
    await subscription.cancel();
    c.dispose();
  });
  test('failed terminal commit blocks later send until save-only retry',
      () async {
    final secrets = ReconcileSecrets()..failCommit = true;
    var posts = 0;
    final c = await setup(secrets, (r) async {
      if (r.method == 'POST') posts++;
      return answer(r);
    });
    await c.send('original');
    expect(c.current!.messages.last.content, 'actual');
    expect(await c.send('must not send'), false);
    expect(posts, 1);
    expect(c.currentRun!.committed, false);
    secrets.failCommit = false;
    await c.retrySave();
    expect(c.currentRun!.committed, true);
    expect(posts, 1);
    c.dispose();
  });
  for (final kind in [
    'pause',
    'source removal',
    'source replacement',
    'session removal',
    'session replacement',
    'dispose'
  ]) {
    for (final boundary in ['discovery', 'status', 'reconcile', 'commit']) {
      test('$kind during $boundary prevents later effects', () async {
        final secrets = ReconcileSecrets();
        final entered = Completer<void>();
        final release = Completer<void>();
        if (boundary == 'reconcile' || boundary == 'commit') {
          secrets.delayCommit = boundary == 'commit';
          secrets.writeEntered = entered;
          secrets.writeRelease = release;
        }
        var posts = 0, alerts = 0;
        final c = await setup(secrets, (r) async {
          if (r.method == 'POST') posts++;
          if ((boundary == 'discovery' &&
                  r.url.path.endsWith('capabilities')) ||
              (boundary == 'status' && r.url.path == '/v1/runs/r')) {
            entered.complete();
            await release.future;
          }
          return answer(r);
        });
        c.onReplyReceived = (_) {
          alerts++;
        };
        final session = c.current!;
        final pending = c.send('original');
        await entered.future;
        final before = secrets.writes;
        invalidate(c, kind);
        release.complete();
        await pending;
        expect(posts, boundary == 'discovery' ? 0 : 1);
        expect(alerts, boundary == 'commit' ? 1 : 0);
        expect(secrets.writes, before);
        expect(c.runs[session.id]?.committed ?? false, false);
        if (boundary == 'discovery' || boundary == 'status') {
          expect(session.messages, isEmpty);
        }
        if (kind != 'dispose') c.dispose();
      });
    }
  }
  for (final kind in [
    'pause',
    'source removal',
    'source replacement',
    'session removal',
    'session replacement',
    'dispose'
  ]) {
    test('$kind during secure read prevents capability GET', () async {
      final secrets = DelayedSecrets();
      var requests = 0;
      final c = await setup(secrets, (r) async {
        requests++;
        return http.Response(jsonEncode(capabilities), 200);
      });
      secrets.entered = Completer<void>();
      secrets.release = Completer<void>();
      final pending = c.send('original');
      await secrets.entered!.future;
      invalidate(c, kind);
      secrets.release!.complete();
      await pending;
      expect(requests, 0);
      if (kind != 'dispose') c.dispose();
    });
  }
}
