import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'agent_runs_test.dart' show capabilities;

class FailingHistory extends SaathiStore {
  FailingHistory(SaathiStore store)
      : super(preferences: store.preferences, secrets: store.secrets);
  bool fail = true;
  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    if (fail) throw StateError('history disk');
    await super.saveChats(chats);
  }
}

class FailingJournal extends MemorySecrets {
  bool fail = false;
  final readIds = <String>[];
  @override
  Future<String?> read(String id) async {
    readIds.add(id);
    return super.read(id);
  }

  @override
  Future<void> write(String id, String value) async {
    if (fail && id.startsWith('run.v1.')) throw StateError('disk');
    await super.write(id, value);
  }
}

Future<ChatController> setup(FailingJournal secrets,
    Future<http.Response> Function(http.Request) handler) async {
  SharedPreferences.setMockInitialValues({});
  final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(), secrets: secrets);
  final c = ChatController(store,
      runClientFactory: (root, key) =>
          RunClient(root, key, client: MockClient(handler)));
  await c.load();
  await c.addConnection(
      {'id': 'h', 'name': 'H', 'type': 'hermes', 'url': 'https://host'},
      'fixture');
  await c.newSession(c.connections.single, 'model', '');
  return c;
}

void main() {
  test('restart after alert before history durability does not alert twice',
      () async {
    final secrets = FailingJournal();
    Future<http.Response> handler(http.Request r) async {
      if (r.url.path.endsWith('capabilities')) {
        return http.Response(jsonEncode(capabilities), 200);
      }
      if (r.method == 'POST') {
        return http.Response('{"run_id":"r","status":"started"}', 202);
      }
      return http.Response(
          '{"run_id":"r","status":"completed","output":"actual"}', 200);
    }

    final initial = await setup(secrets, handler);
    final store = FailingHistory(initial.store);
    initial.dispose();
    ChatController controller() => ChatController(store,
        runClientFactory: (root, key) =>
            RunClient(root, key, client: MockClient(handler)));
    var alerts = 0;
    final c = controller();
    await c.load();
    c.onReplyReceived = (_) {
      alerts++;
    };
    await c.send('original');
    expect(c.unsavedChanges, true);
    c.dispose();
    store.fail = false;
    final restored = controller();
    await restored.load();
    restored.onReplyReceived = (_) {
      alerts++;
    };
    await restored.checkRunStatus();
    await restored.checkRunStatus();
    expect(restored.current!.messages.length, 2);
    expect(alerts, 1);
    restored.dispose();
  });
  test('pending original input remains visible from ledger after restart',
      () async {
    final secrets = FailingJournal();
    final c = await setup(secrets, (r) async {
      if (r.url.path.endsWith('capabilities')) {
        return http.Response(jsonEncode(capabilities), 200);
      }
      if (r.method == 'POST') {
        return http.Response('{"run_id":"r","status":"started"}', 202);
      }
      return http.Response('{"run_id":"r","status":"running"}', 200);
    });
    await c.send('original');
    expect(c.pendingText, 'original');
    c.dispose();
    final restored = ChatController(c.store);
    await restored.load();
    expect(restored.pendingText, 'original');
    restored.dispose();
  });
  for (final boundary in ['discovery', 'status']) {
    test('disposed during $boundary cannot post or persist returned status',
        () async {
      final secrets = FailingJournal();
      final entered = Completer<void>();
      final release = Completer<void>();
      var posts = 0;
      late ChatController c;
      c = await setup(secrets, (r) async {
        if ((boundary == 'discovery' && r.url.path.endsWith('capabilities')) ||
            (boundary == 'status' && r.url.path == '/v1/runs/r')) {
          entered.complete();
          await release.future;
        }
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          posts++;
          return http.Response('{"run_id":"r","status":"started"}', 202);
        }
        return http.Response(
            '{"run_id":"r","status":"completed","output":"stale"}', 200);
      });
      final sending = c.send('original');
      await entered.future;
      c.dispose();
      final before = await secrets.read('run.v1.${c.current!.id}');
      release.complete();
      await sending;
      expect(posts, boundary == 'discovery' ? 0 : 1);
      expect(await secrets.read('run.v1.${c.current!.id}'), before);
      expect(c.current!.messages, isEmpty);
    });
  }
  test('delete recreate identical authority cannot reconnect old operation',
      () async {
    final secrets = FailingJournal();
    var posts = 0;
    var gets = 0;
    final c = await setup(secrets, (r) async {
      if (r.url.path.endsWith('capabilities')) {
        return http.Response(jsonEncode(capabilities), 200);
      }
      if (r.method == 'POST') {
        posts++;
        return http.Response('{"run_id":"r","status":"started"}', 202);
      }
      gets++;
      return http.Response('{"run_id":"r","status":"running"}', 200);
    });
    await c.send('original');
    c.pauseRuns(true);
    final original = Map<String, dynamic>.from(c.connections.single);
    await c.deleteConnection('h');
    await c.addConnection(original, 'fixture');
    expect(c.connections.single['authorityEpoch'],
        isNot(original['authorityEpoch']));
    final loaded = await c.store.load();
    expect(loaded.connections.single['authorityEpoch'],
        c.connections.single['authorityEpoch']);
    secrets.readIds.clear();
    gets = 0;
    c.pauseRuns(false);
    await c.checkRunStatus();
    await c.checkRunStatus();
    expect(secrets.readIds, isEmpty,
        reason:
            'A replacement connection cannot lend credentials to an old run');
    expect(gets, 0);
    expect(posts, 1);
    expect(c.error, contains('removed or replaced connection'));
    expect(c.runObservationProblem, contains('removed or replaced connection'));
    expect(c.showPendingThinking, isFalse);
    c.dispose();
  });
  test('terminal GET journal failure retains actual answer and save-only retry',
      () async {
    final secrets = FailingJournal();
    var posts = 0;
    final c = await setup(secrets, (r) async {
      if (r.url.path.endsWith('capabilities')) {
        return http.Response(jsonEncode(capabilities), 200);
      }
      if (r.method == 'POST') {
        posts++;
        return http.Response('{"run_id":"r","status":"started"}', 202);
      }
      secrets.fail = true;
      return http.Response(
          '{"run_id":"r","status":"completed","output":"actual"}', 200);
    });
    await c.send('original');
    expect(c.current!.messages.map((m) => m.content), ['original', 'actual']);
    secrets.fail = false;
    await c.retrySave();
    final saved = (await RunLedger(secrets).load(c.current!.id))!;
    expect(saved.snapshot.state, RunState.completed);
    expect(saved.committed, true);
    await c.checkRunStatus();
    expect(posts, 1);
    expect(c.current!.messages.length, 2);
    c.dispose();
  });
}
