import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/chat_organization/organization_widgets.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'hermes_gateway_test.dart' show snapshot;

class NativeHost {
  late HttpServer server;
  final sockets = <WebSocket>[];
  final requests = <Map<String, dynamic>>[];
  bool terminal = false;
  bool creationEnabled = false;
  bool listFails = false;
  String profileId = 'profile';
  Completer<void>? resumeGate;
  String? inputId;
  List<Map<String, dynamic>> prompts = [];
  List<Map<String, dynamic>>? history;
  String get url => 'wss://localhost:${server.port}/api/ws';
  String get invite => jsonEncode({
        'state': 'ready',
        'url': url,
        'protocol': 'hermes-gateway-v1',
        'protocols': ['hermes-gateway-v1', 'hermes-gateway-ticket.${'x' * 43}'],
        'ticket': 'x' * 43,
        'endpoint': {'profile_id': profileId, 'instance_id': 'owner'},
      });
  Map<String, dynamic> receipt() => {
        'admission_id': 'run',
        'ref': {'session_id': 'chat', 'profile_id': 'profile'},
        'authority_epoch': 3,
        'execution_generation': 4,
        'status': terminal ? 'terminal' : 'started',
        if (terminal) 'outcome': 'completed',
      };
  Future<void> start() async {
    const cert = 'test/gateway/fixtures/localhost-test-cert.pem';
    SecurityContext.defaultContext.setTrustedCertificates(cert);
    final tls = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey('test/gateway/fixtures/localhost-test-key.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
    server.listen((r) async {
      final ws = await WebSocketTransformer.upgrade(r,
          protocolSelector: (_) => 'hermes-gateway-v1');
      sockets.add(ws);
      ws.listen((raw) async {
        final r = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(r);
        if (r['method'] == 'session.resume') await resumeGate?.future;
        if (r['method'] == 'prompt.submit') {
          inputId = r['params']['input_id'] as String;
        }
        final value = switch (r['method']) {
          'runtime.describe' => {
              'profile_id': profileId,
              'instance_id': 'owner',
              'authority_epoch': 3,
              'capabilities': [
                'durable-admission-v1',
                'event-replay-v1',
                if (creationEnabled) 'local-cli-create-v1'
              ],
              if (creationEnabled)
                'session_create': {
                  'sources': ['gui'],
                  'parameters': ['request_id', 'source']
                },
            },
          'session.list' => {
              'sessions': listFails
                  ? 'invalid window'
                  : [
                      {'session_id': 'chat', 'title': 'Native A'}
                    ]
            },
          'session.resume' => {
              ...snapshot(),
              'session_id': r['params']['session_id'],
              'stored_session_id': r['params']['session_id'],
              'prompts': prompts,
              'messages': history ??
                  [
                    {'row_id': 1, 'role': 'user', 'content': 'Earlier input'},
                    {
                      'row_id': 2,
                      'role': 'assistant',
                      'content': 'Earlier reply'
                    },
                    if (terminal)
                      {
                        'row_id': 3,
                        'role': 'user',
                        'content': 'first',
                        'display_metadata': {'submission_id': inputId}
                      },
                    if (terminal)
                      {
                        'row_id': 4,
                        'role': 'assistant',
                        'content': 'Native final'
                      },
                  ]
            },
          'session.create' => {'session_id': 'new-native'},
          'prompt.submit' || 'prompt.receipt' => receipt(),
          'approval.respond' => (() {
              prompts = [];
              return {'prompt_id': 'approve', 'status': 'resolved'};
            })(),
          'clarify.respond' => (() {
              prompts = [];
              return {'prompt_id': 'clarify', 'status': 'resolved'};
            })(),
          'session.steer' || 'session.redirect' || 'session.interrupt' => {
              'authority_epoch': 3,
              'execution_generation': 4,
              'status': 'queued'
            },
          _ => <String, dynamic>{},
        };
        ws.add(jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': value}));
      });
    });
  }

  void delta(String text) => sockets.last.add(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'message.delta',
          'session_id': 'chat',
          'admission_id': 'run',
          'authority_epoch': 3,
          'execution_generation': 4,
          'replay_epoch': 'replay',
          'seq': requests.length + text.length,
          'payload': {'text': text},
        },
      }));
  Future<void> close() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await server.close(force: true);
  }
}

class GateSecrets extends MemorySecrets {
  Completer<void>? gate;
  bool fail = false;
  String? gatePrefix;
  @override
  Future<void> write(String id, String value) async {
    if (gate != null && (gatePrefix == null || id.startsWith(gatePrefix!))) {
      await gate!.future;
      if (fail) throw StateError('controlled secure write failure');
    }
    await super.write(id, value);
  }
}

Future<(ChatController, NativeHost, GateSecrets)> setup() async {
  final host = NativeHost();
  await host.start();
  final secrets = GateSecrets();
  SharedPreferences.setMockInitialValues({});
  final c = ChatController(SaathiStore(
      preferences: await SharedPreferences.getInstance(), secrets: secrets));
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
  addTearDown(() async {
    c.dispose();
    await host.close();
  });
  return (c, host, secrets);
}

void main() {
  test('delayed native attachment cannot replace a newer selected conversation',
      () async {
    final (c, host, _) = await setup();
    await c.connectCanonical(c.connections.single, host.invite);
    host.resumeGate = Completer<void>();
    final attaching = c.attachCanonical(GatewaySession({'session_id': 'chat'}));
    final assertion = expectLater(attaching, throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final newer =
        ChatSession(id: 'newer', connectionId: 'other', model: 'model');
    c.sessions.add(newer);
    c.select(newer);
    host.resumeGate!.complete();
    await assertion;
    expect(c.current, same(newer));
    expect(c.canonicalFor(c.connections.single), isNull);
  });
  test(
      'foreign or malformed creation evidence cannot block native session access',
      () async {
    final (c, host, secrets) = await setup();
    for (final evidence in [
      '{malformed',
      jsonEncode(
          {'profileId': 'foreign', 'requestId': 'old', 'sessionId': 'old-chat'})
    ]) {
      await secrets.write('gateway.creation.native', evidence);
      final rows = await c.connectCanonical(c.connections.single, host.invite);
      expect(rows, isNotEmpty);
      expect(c.canonicalFor(c.connections.single)!.creation.canCreate, isFalse);
      await c.attachCanonical(rows.first, expectedProfileId: 'profile');
      expect(c.current!.remoteSessionId, 'chat');
      expect(await secrets.read('gateway.creation.native'), evidence);
    }
  });
  test(
      'gateway creation adopts and saves native identity without sending history',
      () async {
    final (c, host, secrets) = await setup();
    final original = c.current!;
    host.creationEnabled = true;
    await c.connectCanonical(c.connections.single, host.invite);
    await c.createCanonical(c.connections.single);
    expect(c.current!.remoteSessionId, 'new-native');
    expect(c.current!.canonicalProfileId, 'profile');
    expect(c.canonical!.connected, isTrue);
    expect(c.sessions, contains(original));
    expect(host.requests.where((r) => r['method'] == 'session.create'),
        hasLength(1));
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
    expect(await secrets.read('gateway.creation.native'), isNull);
    expect(c.store.preferences.getString('saathi.chats.v1'),
        contains('new-native'));
  });
  test(
      'wrong-profile reconnect cannot resume or overwrite the original conversation',
      () async {
    final (c, host, _) = await setup();
    final original = c.current!;
    final before = host.requests.length;
    await expectLater(
        c.attachCanonical(GatewaySession({'session_id': 'chat'}),
            expectedProfileId: 'foreign'),
        throwsStateError);
    expect(c.current, same(original));
    expect(host.requests.length, before);
  });
  test('native connection cannot enter direct-model new-session path',
      () async {
    final (c, host, _) = await setup();
    final original = c.current!;
    await expectLater(c.newSession(c.connections.single, 'model', 'system'),
        throwsStateError);
    expect(c.current, same(original));
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });
  test(
      'canonical completion belongs to original A and organization while B is selected',
      () async {
    final (c, host, _) = await setup();
    final a = c.current!;
    expect(c.personaPolicy(c.identityOf(a)), PersonaEditPolicy.serverOwned);
    expect(await c.send('first'), isTrue);
    final b = ChatSession(id: 'B', connectionId: 'native', model: 'other');
    c.sessions.add(b);
    c.select(b);
    expect(c.workState(a), ConversationWorkState.working);
    host.terminal = true;
    await c.refreshCanonical();
    expect(c.current, same(b));
    final reply = a.messages.singleWhere((m) => m.content == 'Native final');
    expect(reply.id, isNotNull);
    expect(reply.metadata['authoritativeCompletion'], isTrue);
    expect(c.organization.entry(c.identityOf(a)).unread, isTrue);
    expect(b.messages, isEmpty);
    c.select(a);
    expect(c.canonical!.connected, isFalse);
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });
  for (final fail in [false, true]) {
    test(
        'canonical key mutation revokes at START through delayed write failure=$fail',
        () async {
      final (c, host, secrets) = await setup();
      final owner = c.canonical!;
      secrets.gate = Completer<void>();
      secrets.gatePrefix = 'credential.v1.';
      secrets.fail = fail;
      final change = c.updateConnection('native', {...c.connections.single},
          apiKey: 'replacement');
      final asserted = fail ? expectLater(change, throwsA(anything)) : change;
      expect(owner.connected, isFalse);
      expect(await owner.control('steer', text: 'never'), isFalse);
      secrets.gate!.complete();
      await asserted;
      expect(owner.connected, isFalse);
      expect(await c.send('never revive'), isFalse);
      expect(
          host.requests.where((r) =>
              r['method'] == 'prompt.submit' || r['method'] == 'prompt.steer'),
          isEmpty);
    });
  }
  test(
      'canonical restored prepared journal requires Resume and preserves exact native FIFO ordering',
      () async {
    final (c, host, secrets) = await setup();
    const key = 'gateway.journal.native.chat';
    await secrets.write(
        key,
        jsonEncode({
          'inputId': 'prepared-input',
          'text': 'first',
          'sessionId': 'chat',
          'profileId': 'profile',
          'state': 'prepared'
        }));
    await c.connectCanonical(c.connections.single, host.invite);
    await c.attachCanonical(
        GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
    expect(c.outbox.map((i) => i.text), ['first']);
    expect(c.queueStatus, contains('Resume'));
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
    expect(await secrets.read(key), isNotNull);
    c.resumeQueue();
    for (var i = 0; i < 40 && host.inputId == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
    expect(
        host.requests.lastWhere((r) => r['method'] == 'prompt.submit')['params']
            ['text'],
        'first');
    expect(c.runPending, isTrue);
    for (var i = 0; i < 40 && c.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.submit('second'), isTrue);
    // An admission or elapsed timer never dispatches the next accepted input.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.outbox.map((i) => i.text), ['second']);
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });
  test(
      'legacy canonical rows remain unscoped and read-only rather than overwritten',
      () async {
    final (c, host, _) = await setup();
    final scoped = c.current!;
    final legacy = ChatSession(
        id: 'legacy',
        connectionId: 'native',
        model: 'Hermes Desktop / CLI',
        remoteSessionId: 'chat');
    c.sessions.add(legacy);
    c.select(legacy);
    expect(c.readOnly, isTrue);
    await c.connectCanonical(c.connections.single, host.invite);
    await c.attachCanonical(
        GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
    expect(c.current, same(scoped));
    expect(legacy.canonicalProfileId, isNull);
    expect(legacy.messages, isEmpty);
  });
  test('canonical background resume never revives an existing grant', () async {
    final (c, host, _) = await setup();
    final owner = c.canonical!;
    c.pauseRuns(true);
    c.pauseRuns(false);
    expect(owner.connected, isFalse);
    expect(await c.send('never revive'), isFalse);
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });
  test(
      'canonical accepted FIFO followers survive controller recreation without replaying admitted head',
      () async {
    final (c, host, _) = await setup();
    expect(await c.send('first'), isTrue);
    expect(c.submit('second'), isTrue);
    expect(c.submit('third'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await c.persist();
    c.pauseRuns(true);
    final restored = ChatController(c.store);
    addTearDown(restored.dispose);
    await restored.load();
    await restored.connectCanonical(restored.connections.single, host.invite);
    await restored.attachCanonical(
        GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
    expect(restored.outbox.map((i) => i.text), ['second', 'third']);
    expect(restored.queueStatus, contains('Resume'));
    expect(restored.runPending, isTrue);
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });

  test(
      'canonical failed FIFO save retries storage only and keeps explicit Resume through exact source completion',
      () async {
    final (c, host, secrets) = await setup();
    expect(await c.send('first'), isTrue);
    secrets.gate = Completer<void>();
    secrets.gatePrefix = 'gateway.fifo.';
    secrets.fail = true;
    expect(c.submit('second'), isTrue);
    await Future<void>.delayed(Duration.zero);
    secrets.gate!.complete();
    for (var i = 0; i < 40 && !c.unsavedChanges; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.unsavedChanges, isTrue);
    expect(c.outbox.map((i) => i.text), ['second']);
    secrets.gate = null;
    secrets.fail = false;
    final before = host.requests.length;
    await c.retrySave();
    expect(host.requests.length, before,
        reason: 'FIFO retry is secure storage only');
    expect(c.unsavedChanges, isFalse);
    host.terminal = true;
    await c.refreshCanonical();
    expect(c.runPending, isFalse);
    expect(c.queueStatus, contains('Resume'));
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
    c.resumeQueue();
    for (var i = 0;
        i < 40 &&
            host.requests.where((r) => r['method'] == 'prompt.submit').length <
                2;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(2));
    expect(
        host.requests.lastWhere((r) => r['method'] == 'prompt.submit')['params']
            ['text'],
        'second');
  });
  test(
      'fresh canonical reconnect holds already mounted followers for explicit Resume',
      () async {
    final (c, host, _) = await setup();
    expect(await c.send('first'), isTrue);
    expect(c.submit('second'), isTrue);
    for (var i = 0; i < 40 && c.canonicalQueueSaving; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await c.connectCanonical(c.connections.single, host.invite);
    await c.attachCanonical(
        GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
    expect(c.outbox.map((i) => i.text), ['second']);
    expect(c.queueStatus, contains('Resume'));
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });

  test(
      'failed native FIFO cancellation preserves admitted journal and exact follower on recreation',
      () async {
    final (c, host, secrets) = await setup();
    expect(await c.send('first'), isTrue);
    expect(c.submit('second'), isTrue);
    for (var i = 0; i < 40 && c.canonicalQueueSaving; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final journal = await secrets.read('gateway.journal.native.chat');
    secrets.gate = Completer<void>()..complete();
    secrets.gatePrefix = 'gateway.fifo.';
    secrets.fail = true;
    await c.cancelQueued(c.outbox.single);
    expect(c.outbox.map((i) => i.text), ['second']);
    expect(await secrets.read('gateway.journal.native.chat'), journal);
    secrets.gate = null;
    secrets.fail = false;
    c.pauseRuns(true);
    final restored = ChatController(c.store);
    addTearDown(restored.dispose);
    await restored.load();
    await restored.connectCanonical(restored.connections.single, host.invite);
    await restored.attachCanonical(
        GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
    expect(restored.outbox.map((i) => i.text), ['second']);
    await restored.cancelQueued(restored.outbox.single);
    expect(restored.outbox, isEmpty);
    expect(await secrets.read('gateway.journal.native.chat'), journal);
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });
}
