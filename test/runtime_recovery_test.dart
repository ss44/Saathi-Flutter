import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_activity/activity_owner.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'runtime_flow_test.dart' show RuntimeFixture;

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class DelayedSecrets extends MemorySecrets {
  bool hold = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<String?> read(String id) async {
    if (hold && id == 'h') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.read(id);
  }
}

Future<ChatController> connect(RuntimeFixture fixture,
    {SecretStore? secrets}) async {
  SharedPreferences.setMockInitialValues({});
  final c = ChatController(SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: secrets ?? MemorySecrets()));
  await c.load();
  await c.addConnection({
    'id': 'h',
    'name': 'Original',
    'type': 'hermes',
    'url': 'http://127.0.0.1:${fixture.server.port}'
  }, 'fixture');
  await c.continueRemote(
      c.connections.single,
      RemoteSession({
        'id': 'external_chat',
        'source': 'api_server',
        'title': 'External chat',
        'model': 'original-model',
        'provider': 'original-provider'
      }));
  return c;
}

void main() {
  test(
      'localhost mismatched status session cannot settle selected conversation',
      () async {
    final f = RuntimeFixture()
      ..completed = true
      ..statusSessionId = 'foreign_chat';
    await f.start();
    var c = await connect(f);
    addTearDown(() async {
      c.dispose();
      await f.close();
    });
    var notifications = 0;
    c.onReplyReceived = (_) => notifications++;
    await c.send('new input');
    final original = c.current!;
    final operationData = jsonDecode(jsonEncode(c.currentRun!.data));
    final journal = await c.store.secrets.read('run.v1.${original.id}');
    expect(c.runPending, isTrue);
    expect(c.current!.messages, hasLength(2));
    // Policy reconciliation: reject foreign content immediately, but present a
    // failed observation (not a confirmed execution failure) during the budget.
    expect(c.error, isNull);
    expect(c.runObservationProblem, 'Reconnecting to check your reply');
    expect(c.showPendingThinking, isTrue);
    expect(c.submit('held follower'), isTrue);
    for (var i = 0; i < 3; i++) {
      await c.checkRunStatus();
      expect(c.current!.messages, hasLength(2));
      expect(c.currentRun!.data, operationData);
      expect(await c.store.secrets.read('run.v1.${original.id}'), journal);
      expect(notifications, 0);
      expect(f.submissions, 1);
    }
    expect(c.showPendingThinking, isFalse);
    expect(c.runObservationProblem, contains('Use Check status'));
    expect(c.queueStatus, isNotNull);
    expect(c.canResumeQueue, isFalse);
    expect(c.currentRun!.committed, isFalse);
    expect(c.outbox.single.text, 'held follower');
    final store = c.store;
    c.dispose();
    c = ChatController(store);
    await c.load();
    expect(c.current!.id, original.id);
    expect(c.current!.messages, hasLength(2));
    expect(await store.secrets.read('run.v1.${original.id}'), journal);
    // A later valid response can settle the original after recreation, once.
    f.statusSessionId = 'external_chat';
    c.onReplyReceived = (_) => notifications++;
    await c.checkRunStatus();
    await c.checkRunStatus();
    expect(c.runPending, isFalse);
    expect(c.currentRun!.committed, isTrue);
    expect(c.current!.messages, hasLength(4));
    expect(c.current!.messages.last.content, 'Authoritative final response');
    expect(notifications, 1);
    expect(f.submissions, 1);
  });
  test('control status completion wakes the existing FIFO scheduler', () async {
    final f = RuntimeFixture();
    await f.start();
    final c = await connect(f);
    await c.send('first');
    expect(c.submit('follower'), isTrue);
    expect(f.submissions, 1);
    f.completed = true;
    await c.controlRun(guidance: 'Never send this obsolete guidance');
    await until(() => f.submissions == 2);
    expect(f.guides, isEmpty);
    expect(f.inputs.map((m) => m['input']), ['first', 'follower']);
    c.dispose();
    await f.close();
  });
  test('attachment owner disposal revokes delayed credentials before HTTP',
      () async {
    final f = RuntimeFixture();
    await f.start();
    final secrets = DelayedSecrets();
    final c = await connect(f, secrets: secrets);
    var current = true;
    secrets.hold = true;
    final before = f.requests.length;
    final attaching = c.continueRemote(c.connections.single,
        RemoteSession({'id': 'external_chat', 'source': 'api_server'}),
        isOwnerCurrent: () => current);
    final rejected = expectLater(attaching, throwsStateError);
    await secrets.entered.future;
    current = false;
    secrets.release.complete();
    await rejected;
    expect(f.requests, hasLength(before));
    expect(c.sessions, hasLength(1));
    c.dispose();
    await f.close();
  });
  for (final boundary in ['lifecycle', 'rotation', 'selection']) {
    test('attachment $boundary revokes delayed credentials before HTTP',
        () async {
      final f = RuntimeFixture();
      await f.start();
      final secrets = DelayedSecrets();
      final c = await connect(f, secrets: secrets);
      secrets.hold = true;
      final before = f.requests.length;
      final attaching = c.continueRemote(c.connections.single,
          RemoteSession({'id': 'external_chat', 'source': 'api_server'}));
      final rejected = expectLater(attaching, throwsStateError);
      await secrets.entered.future;
      if (boundary == 'lifecycle') {
        c.pauseRuns(true);
        c.pauseRuns(false);
      } else if (boundary == 'rotation') {
        c.connections[0] = {
          ...c.connections.single,
          'authorityEpoch': 'replacement'
        };
      } else {
        c.current = null;
      }
      secrets.release.complete();
      await rejected;
      expect(f.requests, hasLength(before));
      expect(c.sessions, hasLength(1));
      c.dispose();
      await f.close();
    });
  }
  test(
      'localhost lost admission ACK survives restart with identical bytes and identity',
      () async {
    final f = RuntimeFixture()..loseFirstAck = true;
    await f.start();
    var c = await connect(f);
    addTearDown(() async {
      c.dispose();
      await f.close();
    });
    expect(c.current!.messages, hasLength(2),
        reason: 'existing private context is nonempty before submission');
    expect(await c.send('only new input'), isTrue);
    expect(c.runPending, isTrue);
    expect(c.currentRun!.runId, isNull);
    expect(f.inputs.single,
        {'input': 'only new input', 'session_id': 'external_chat'});
    final store = c.store;
    final original = c.current!;
    final operationData = jsonDecode(jsonEncode(c.currentRun!.data));
    final journalKey = 'run.v1.${original.id}';
    final journal = await store.secrets.read(journalKey);
    expect(journal, isNotNull);
    expect(c.currentRun!.payload, f.inputBytes.single);
    expect(c.currentRun!.key, f.inputKeys.single);
    expect(c.currentRun!.data['attempted'], isTrue);
    expect(c.currentRun!.committed, isFalse);
    expect(c.currentRun!.data['authorityEpoch'],
        c.connections.single['authorityEpoch']);
    expect(c.currentRun!.data['origin'], c.connections.single['url']);
    c.dispose();
    c = ChatController(store);
    await c.load();
    expect(f.submissions, 1);
    expect(c.current!.id, original.id);
    expect(c.current!.remoteSessionId, 'external_chat');
    expect(c.current!.model, 'original-model');
    expect(c.current!.upstreamProvider, 'original-provider');
    expect(c.currentRun!.data, operationData);
    expect(await store.secrets.read(journalKey), journal);
    f.completed = true;
    // Policy reconciliation: the old second-identical-POST assertion did not
    // prove single execution. Runs has no read-only key lookup; no run ID means
    // retain uncertainty, even when the peer now has a completed response.
    expect(c.submit('held follower'), isTrue);
    for (var i = 0; i < 3; i++) {
      await c.checkRunStatus();
      expect(c.runPending, isTrue);
      expect(c.currentRun!.runId, isNull);
      expect(c.currentRun!.committed, isFalse);
      expect(c.showPendingThinking, isFalse);
      expect(c.runObservationProblem, contains('without its reply ID'));
      expect(c.currentRun!.data, operationData);
      expect(await store.secrets.read(journalKey), journal);
    }
    c.pauseRuns(true);
    c.pauseRuns(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.outbox.single.text, 'held follower');
    expect(c.canResumeQueue, isFalse);
    expect(f.inputBytes, [operationData['payload']]);
    expect(f.inputKeys, [operationData['key']]);
    expect(f.requests.where((r) => r == 'GET /v1/runs/run_fixture'), isEmpty);
    expect(c.current!.messages.map((m) => m.content),
        ['External context', 'Existing reply']);
    // A second recreation still preserves exact bytes, identity and uncertainty.
    c.dispose();
    c = ChatController(store);
    await c.load();
    await c.checkRunStatus();
    expect(c.currentRun!.data, operationData);
    expect(await store.secrets.read(journalKey), journal);
    expect(c.runPending, isTrue);
    expect(c.current!.messages, hasLength(2));
    expect(f.submissions, 1);
  });

  test(
      'localhost replayed delta and completion never duplicate result or infer again',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final f = RuntimeFixture();
    await f.start();
    final c = await connect(f);
    final owner = ActivityOwner(c);
    await c.send('new input');
    await until(() => c.streamingText != null);
    f.sequence = 0;
    f.emit('message.delta', {'delta': 'Visible response in progress'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(c.streamingText, 'Visible response in progress');
    f.completed = true;
    f.emit('run.completed', {'output': 'Untrusted SSE text'});
    await until(() => !c.runPending);
    f.emit('run.completed', {'output': 'Untrusted replay'});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(c.current!.messages.last.content, 'Authoritative final response');
    expect(c.current!.messages, hasLength(4));
    expect(f.submissions, 1);
    owner.dispose();
    c.dispose();
    await f.close();
  });

  test('localhost late completion belongs to original chat, not selected chat',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final f = RuntimeFixture();
    await f.start();
    final c = await connect(f);
    final owner = ActivityOwner(c);
    await c.send('new input');
    final original = c.current!;
    await until(() => c.streamingText != null);
    await c.newSession(
        c.connections.single, 'other-model', 'different instructions');
    final other = c.current!;
    f.completed = true;
    f.emit('run.completed', {'output': 'not authoritative'});
    await until(() => c.runs[original.id]!.committed);
    expect(other.messages, isEmpty);
    expect(c.streamingText, isNull);
    expect(original.messages.last.content, 'Authoritative final response');
    expect(f.submissions, 1);
    owner.dispose();
    c.dispose();
    await f.close();
  });

  for (final output in [null, 7, <String, Object?>{}, '']) {
    test('localhost malformed or empty terminal output is explicit: $output',
        () async {
      final f = RuntimeFixture()
        ..completed = true
        ..terminalOutput = output;
      await f.start();
      final c = await connect(f);
      addTearDown(() async {
        c.dispose();
        await f.close();
      });
      var notifications = 0;
      c.onReplyReceived = (_) => notifications++;
      await c.send('new input');
      if (output is! String) {
        final journalKey = 'run.v1.${c.current!.id}';
        final journal = await c.store.secrets.read(journalKey);
        expect(c.runPending, isTrue);
        // Policy reconciliation: malformed status is a rejected observation,
        // never terminal success; allow bounded recovery instead of error flash.
        expect(c.error, isNull);
        expect(c.runObservationProblem, 'Reconnecting to check your reply');
        expect(c.showPendingThinking, isTrue);
        expect(c.submit('held follower'), isTrue);
        for (var i = 0; i < 3; i++) {
          await c.checkRunStatus();
          expect(c.currentRun!.snapshot.state, RunState.running);
          expect(c.currentRun!.committed, isFalse);
          expect(c.current!.messages, hasLength(2));
          expect(await c.store.secrets.read(journalKey), journal);
          expect(notifications, 0);
          expect(f.submissions, 1);
        }
        expect(c.runObservationProblem, contains('Use Check status'));
        expect(c.showPendingThinking, isFalse);
        expect(c.runPending, isTrue);
        expect(c.canResumeQueue, isFalse);
        expect(c.queueStatus, isNotNull);
        expect(c.outbox.single.text, 'held follower');
        // Exhaustion is not a dead end. Valid original output settles once;
        // an intentional pause still keeps the accepted follower on this device.
        c.pauseQueue('Paused by you');
        f.terminalOutput = 'Recovered valid answer';
        await c.checkRunStatus();
        await c.checkRunStatus();
        expect(c.currentRun!.committed, isTrue);
        expect(c.runPending, isFalse);
        expect(c.runObservationProblem, isNull);
        expect(c.current!.messages, hasLength(4));
        expect(c.current!.messages.last.content, 'Recovered valid answer');
        expect(c.queueStatus, 'Paused by you');
        expect(c.outbox.single.text, 'held follower');
        expect(notifications, 1);
      } else {
        expect(c.runPending, isFalse);
        expect(c.error, contains('without a text response'));
        expect(c.showPendingThinking, isFalse);
        expect(c.currentRun!.committed, isTrue);
        expect(notifications, 0);
        expect(c.current!.messages.last.metadata['authoritativeCompletion'],
            isNot(true));
      }
      expect(f.submissions, 1);
    });
  }
}
