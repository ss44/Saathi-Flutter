import 'dart:async';
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
    final c = await connect(f);
    await c.send('new input');
    expect(c.runPending, isTrue);
    expect(c.current!.messages, hasLength(2));
    expect(c.error, isNotNull);
    expect(f.submissions, 1);
    c.dispose();
    await f.close();
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
    expect(await c.send('only new input'), isTrue);
    expect(c.runPending, isTrue);
    expect(c.currentRun!.runId, isNull);
    final store = c.store;
    c.dispose();
    c = ChatController(store);
    await c.load();
    expect(f.submissions, 1);
    expect(c.current!.remoteSessionId, 'external_chat');
    expect(c.current!.model, 'original-model');
    expect(c.current!.upstreamProvider, 'original-provider');
    f.completed = true;
    await c.checkRunStatus();
    expect(f.inputBytes, [f.inputBytes.first, f.inputBytes.first]);
    expect(f.inputKeys, [f.inputKeys.first, f.inputKeys.first]);
    expect(c.runPending, isFalse);
    await c.checkRunStatus();
    expect(
        c.current!.messages
            .where((m) => m.content == 'Authoritative final response'),
        hasLength(1));
    c.dispose();
    await f.close();
  });

  test(
      'localhost replayed delta and completion never duplicate result or infer again',
      () async {
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

  for (final output in [null, 7, '']) {
    test('localhost malformed or empty terminal output is explicit: $output',
        () async {
      final f = RuntimeFixture()
        ..completed = true
        ..terminalOutput = output;
      await f.start();
      final c = await connect(f);
      await c.send('new input');
      if (output is! String) {
        expect(c.runPending, isTrue);
        expect(c.error, isNotNull);
        expect(c.runObservationProblem, isNotNull);
      } else {
        expect(c.runPending, isFalse);
        expect(c.error, contains('without a text response'));
      }
      expect(f.submissions, 1);
      c.dispose();
      await f.close();
    });
  }
}
