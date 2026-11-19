import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'gateway/canonical_combined_controller_test.dart' as native;
import 'agent_run_hardening_test.dart' as runs;
import 'agent_run_controller_safety_test.dart' show DelayedHistory, answer;
import 'agent_runs_test.dart' show capabilities;

// Normalized copy of the independent cycle-1 acceptance probes.
// Raw source and its RED evidence are preserved outside the analyzed tree.
class FailureHost extends native.NativeHost {
  FailureHost({this.outcome = 'failed'});
  final String outcome;
  @override
  Map<String, dynamic> receipt() => {
        ...super.receipt(),
        if (terminal) 'outcome': outcome,
      };
}

class ToggleHistory extends SaathiStore {
  ToggleHistory({required super.preferences, required super.secrets});
  bool fail = false;
  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    if (fail) throw StateError('review controlled save failure');
    await super.saveChats(chats);
  }
}

void main() {
  test(
      'review: exhausted recovery then failed terminal permits deliberate Resume',
      () async {
    var posts = 0;
    var unavailable = true;
    final c = await runs.setup(runs.FailingJournal(), (r) async {
      if (r.url.path.endsWith('capabilities')) {
        return http.Response(jsonEncode(capabilities), 200);
      }
      if (r.method == 'POST') {
        posts++;
        return http.Response(
            jsonEncode({'run_id': 'r$posts', 'status': 'started'}), 202);
      }
      if (unavailable) return http.Response('{}', 503);
      return http.Response(
          jsonEncode(
              {'run_id': r.url.path.split('/').last, 'status': 'failed'}),
          200);
    });
    addTearDown(c.dispose);
    await c.send('first');
    expect(c.submit('follower'), isTrue);
    for (var i = 0; i < 3; i++) {
      await c.checkRunStatus();
    }
    unavailable = false;
    await c.checkRunStatus();
    expect(c.currentRun!.committed, isTrue);
    expect(c.canResumeQueue, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(posts, 1,
        reason: 'Failed settlement still requires deliberate Resume');
    c.resumeQueue();
    final deadline = Stopwatch()..start();
    while (posts == 1 && deadline.elapsed < const Duration(milliseconds: 300)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(posts, 2,
        reason: 'Manual Resume must clear resolved automatic recovery barrier');
  });
  test('review: running canonical resync must retain thinking', () async {
    final (c, _, _) = await native.setup();
    await c.send('first');
    expect(c.showPendingThinking, isTrue);
    await c.refreshCanonical();
    expect(c.canonical!.client.run!.state, GatewayRunState.running);
    expect(c.runPending, isTrue);
    expect(c.unsavedChanges, isFalse);
    expect(c.showPendingThinking, isTrue,
        reason: 'A saved nonterminal snapshot is not completion');
  });
  test('review: first Runs terminal answer must stop thinking during save',
      () async {
    final initial =
        await runs.setup(runs.FailingJournal(), (r) async => answer(r));
    final store = DelayedHistory(initial.store);
    initial.dispose();
    final c = ChatController(store,
        runClientFactory: (root, key) =>
            RunClient(root, key, client: MockClient((r) async => answer(r))));
    await c.load();
    final sending = c.send('first');
    await store.entered.future.timeout(const Duration(seconds: 3));
    try {
      expect(c.currentRun!.snapshot.state, RunState.completed);
      expect(c.runPending, isTrue);
      expect(c.showPendingThinking, isFalse,
          reason: 'Only persistence remains, not inference');
    } finally {
      store.release.complete();
      await sending;
      c.dispose();
    }
  });
  for (final outcome in ['failed', 'cancelled']) {
    for (final retryStorage in [true, false]) {
      for (final explicitPause in [false, true]) {
        test(
            'review: $outcome canonical reply stays held after storage retry=$retryStorage explicit=$explicitPause',
            () async {
          final host = FailureHost(outcome: outcome);
          await host.start();
          SharedPreferences.setMockInitialValues({});
          final store = ToggleHistory(
              preferences: await SharedPreferences.getInstance(),
              secrets: MemorySecrets());
          final c = ChatController(store);
          addTearDown(() async {
            c.dispose();
            await host.close();
          });
          await c.load();
          await c.addConnection({
            'id': 'native',
            'name': 'Native',
            'type': 'hermesGateway',
            'url': host.url
          }, '');
          await c.connectCanonical(c.connections.single, host.invite);
          await c.attachCanonical(
              GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
          await c.send('first');
          expect(c.submit('follower'), isTrue);
          while (c.canonicalQueueSaving) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          if (explicitPause) c.pauseQueue('Paused by you');
          store.fail = retryStorage;
          host.terminal = true;
          await c.refreshCanonical();
          expect(c.unsavedChanges, retryStorage);
          expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
              hasLength(1));
          store.fail = false;
          if (retryStorage) await c.retrySave();
          final deadline = Stopwatch()..start();
          while (host.requests
                      .where((r) => r['method'] == 'prompt.submit')
                      .length ==
                  1 &&
              deadline.elapsed < const Duration(milliseconds: 300)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          while (c.busy && deadline.elapsed < const Duration(seconds: 3)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
              hasLength(1),
              reason:
                  'Failed reply requires review, saving is not permission to send follower');
          expect(c.queueStatus, isNotNull);
          if (explicitPause) expect(c.queueStatus, 'Paused by you');
        });
      }
    }
  }
}
