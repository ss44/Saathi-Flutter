import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'hermes_gateway_test.dart' show Fixture, snapshot;

class TlsFixture {
  late HttpServer server;
  final sockets = <WebSocket>[];
  final requests = <Map<String, dynamic>>[];
  String profile = 'profile';
  Future<void> start() async {
    const dir = 'test/gateway/fixtures';
    SecurityContext.defaultContext
        .setTrustedCertificates('$dir/localhost-test-cert.pem');
    final tls = SecurityContext()
      ..useCertificateChain('$dir/localhost-test-cert.pem')
      ..usePrivateKey('$dir/localhost-test-key.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request,
          protocolSelector: (_) => 'hermes-gateway-v1');
      sockets.add(socket);
      socket.listen((frame) {
        final request = jsonDecode(frame as String) as Map<String, dynamic>;
        requests.add(request);
        final method = request['method'];
        final result = switch (method) {
          'runtime.describe' => {
              'profile_id': profile,
              'instance_id': 'owner',
              'capabilities': ['durable-admission-v1']
            },
          'session.list' => {
              'sessions': [
                {'session_id': 'chat', 'title': 'A'}
              ]
            },
          'session.resume' => {
              ...snapshot(),
              'messages': [
                {'role': 'assistant', 'content': 'history for $profile'}
              ],
              'prompts': [
                {
                  'kind': 'approval',
                  'prompt_id': 'approve',
                  'command': 'echo reviewable fixture',
                  'execution_generation': 4,
                  'choices': ['once', 'deny']
                }
              ]
            },
          'approval.respond' => {'prompt_id': 'approve', 'status': 'resolved'},
          _ => <String, dynamic>{},
        };
        socket.add(jsonEncode(
            {'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
      });
    });
  }

  String get url => 'wss://localhost:${server.port}/api/ws';
  String invite() {
    final ticket = List.filled(43, 'a').join();
    return jsonEncode({
      'state': 'ready',
      'url': url,
      'protocol': 'hermes-gateway-v1',
      'ticket': ticket,
      'protocols': ['hermes-gateway-v1', 'hermes-gateway-ticket.$ticket'],
      'endpoint': {'profile_id': profile, 'instance_id': 'owner'}
    });
  }

  Future<void> close() async {
    for (final s in sockets) {
      await s.close();
    }
    await server.close(force: true);
  }
}

void main() {
  test('newSession A-B-A must irreversibly revoke canonical decisions',
      () async {
    SharedPreferences.setMockInitialValues({});
    final f = TlsFixture();
    await f.start();
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    addTearDown(() async {
      c.dispose();
      await f.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'type': 'hermesGateway',
      'name': 'native',
      'url': f.url
    }, '');
    await c.addConnection({
      'id': 'direct',
      'type': 'openai',
      'name': 'direct',
      'url': 'https://example.invalid'
    }, '');
    final rows = await c.connectCanonical(c.connections.first, f.invite());
    await c.attachCanonical(rows.first);
    final a = c.current!;
    final owner = c.canonical!;
    final prompt = owner.snapshot!.requests.single;
    await c.newSession(c.connections.last, 'model', '');
    final connectedInB = owner.connected;
    c.select(a);
    owner.onResyncRequired = null;
    final accepted = await owner.decide(prompt, 'once');
    stdout.writeln(
        'REPRO selection: connectedInB=$connectedInB connectedAfterABA=${owner.connected} decisionAccepted=$accepted approvalRPCs=${f.requests.where((r) => r['method'] == 'approval.respond').length}');
    expect(connectedInB, isFalse,
        reason:
            'newSession must revoke old canonical authority at selection START');
    expect(accepted, isFalse);
  });
  test(
      'direct selected-owner transitions must irreversibly revoke canonical decisions',
      () async {
    SharedPreferences.setMockInitialValues({});
    final f = TlsFixture();
    await f.start();
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    addTearDown(() async {
      c.dispose();
      await f.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'type': 'hermesGateway',
      'name': 'native',
      'url': f.url
    }, '');
    await c.addConnection({
      'id': 'direct',
      'type': 'openai',
      'name': 'direct',
      'url': 'https://example.invalid'
    }, '');
    final rows = await c.connectCanonical(c.connections.first, f.invite());
    await c.attachCanonical(rows.first);
    final a = c.current!;
    final owner = c.canonical!;
    final prompt = owner.snapshot!.requests.single;
    final b =
        ChatSession(id: 'direct-b', connectionId: 'direct', model: 'model');
    c.sessions.add(b);
    c.current = b;
    final connectedInB = owner.connected;
    c.select(a);
    owner.onResyncRequired = null;
    final accepted = await owner.decide(prompt, 'once');
    stdout.writeln(
        'REPRO selection: connectedInB=$connectedInB connectedAfterABA=${owner.connected} decisionAccepted=$accepted approvalRPCs=${f.requests.where((r) => r['method'] == 'approval.respond').length}');
    expect(connectedInB, isFalse,
        reason:
            'newSession must revoke old canonical authority at selection START');
    expect(accepted, isFalse);
  });
  test('failed newSession save cannot revive canonical decisions', () async {
    SharedPreferences.setMockInitialValues({});
    final f = TlsFixture();
    await f.start();
    final c = FailingCreateController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    addTearDown(() async {
      c.dispose();
      await f.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'type': 'hermesGateway',
      'name': 'native',
      'url': f.url
    }, '');
    await c.addConnection({
      'id': 'direct',
      'type': 'openai',
      'name': 'direct',
      'url': 'https://example.invalid'
    }, '');
    final rows = await c.connectCanonical(c.connections.first, f.invite());
    await c.attachCanonical(rows.first);
    final a = c.current!;
    final owner = c.canonical!;
    final prompt = owner.snapshot!.requests.single;
    c.failNextSave = true;
    await expectLater(
        c.newSession(c.connections.last, 'model', ''), throwsStateError);
    expect(c.current, same(a));
    owner.onResyncRequired = null;
    expect(owner.connected, isFalse,
        reason:
            'new-conversation authority is revoked before save, even if save fails');
    expect(await owner.decide(prompt, 'once'), isFalse);
    expect(f.requests.where((r) => r['method'] == 'approval.respond'), isEmpty);
  });
  test('failed clear save cannot revive canonical decisions', () async {
    SharedPreferences.setMockInitialValues({});
    final f = TlsFixture();
    await f.start();
    final c = FailingCreateController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    addTearDown(() async {
      c.dispose();
      await f.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'type': 'hermesGateway',
      'name': 'native',
      'url': f.url
    }, '');
    await c.addConnection({
      'id': 'direct',
      'type': 'openai',
      'name': 'direct',
      'url': 'https://example.invalid'
    }, '');
    final rows = await c.connectCanonical(c.connections.first, f.invite());
    await c.attachCanonical(rows.first);
    final a = c.current!;
    final owner = c.canonical!;
    final prompt = owner.snapshot!.requests.single;
    c.failNextSave = true;
    await expectLater(c.clear(), throwsStateError);
    expect(c.current, same(a));
    owner.onResyncRequired = null;
    expect(owner.connected, isFalse,
        reason:
            'new-conversation authority is revoked before save, even if save fails');
    expect(await owner.decide(prompt, 'once'), isFalse);
    expect(f.requests.where((r) => r['method'] == 'approval.respond'), isEmpty);
  });
  test(
      'same endpoint and session under a different profile must not alias local history',
      () async {
    SharedPreferences.setMockInitialValues({});
    final f = TlsFixture();
    await f.start();
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    addTearDown(() async {
      c.dispose();
      await f.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'type': 'hermesGateway',
      'name': 'native',
      'url': f.url
    }, '');
    var rows = await c.connectCanonical(c.connections.first, f.invite());
    await c.attachCanonical(rows.first);
    final original = c.current!;
    f.profile = 'different-profile';
    rows = await c.connectCanonical(c.connections.first, f.invite());
    await c.attachCanonical(rows.first);
    stdout.writeln(
        'REPRO profile alias: runtimeProfile=${c.canonical!.client.profileId} reusedOriginalLocalSession=${identical(c.current, original)} localSessionCount=${c.sessions.length} originalHistoryNow=${original.messages.map((m) => m.content).toList()}');
    expect(identical(c.current, original), isFalse,
        reason:
            'profile is part of original conversation authority, not just endpoint/session string');
    expect(original.canonicalProfileId, 'profile');
    expect(c.current!.canonicalProfileId, 'different-profile');
    final saved =
        jsonDecode(c.store.preferences.getString('saathi.chats.v1')!) as List;
    expect(saved.map((r) => r['canonicalProfileId']),
        containsAll(['profile', 'different-profile']));
    expect(
        ChatSession.fromJson(original.toJson()).canonicalProfileId, 'profile');
    expect(original.messages.single.content, 'history for profile');
  });
  test('send journal must retain the original session across attach', () async {
    final f = Fixture();
    await f.start();
    f.respond = (r) => r['method'] == 'session.resume'
        ? {...snapshot(), 'session_id': r['params']['session_id']}
        : {
            'admission_id': 'run',
            'ref': {
              'profile_id': 'profile',
              'session_id': r['params']['session_id']
            },
            'authority_epoch': 3,
            'execution_generation': 4,
            'status': 'started'
          };
    final secrets = GateSecrets();
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => f.grant()), secrets,
        source: 'source', isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await f.close();
    });
    await chat.connect();
    await chat.attach('A');
    await secrets.write(
        'gateway.journal.source.B',
        jsonEncode({
          'inputId': 'input-b',
          'text': 'B held draft',
          'sessionId': 'B',
          'profileId': 'profile',
          'state': 'prepared'
        }));
    final sending = chat.send('A private draft');
    await secrets.started.future;
    final attaching = chat.attach('B');
    final writableDuringAttach = chat.connected;
    await attaching;
    secrets.gate.complete();
    Object? error;
    try {
      await sending;
    } catch (e) {
      error = e;
    }
    final posts =
        f.requests.where((r) => r['method'] == 'prompt.submit').toList();
    stdout.writeln(
        'REPRO attach during preparation: error=$error submitted=${posts.map((r) => r['params']).toList()} journalA=${await secrets.read('gateway.journal.source.A')}');
    expect(writableDuringAttach, isFalse,
        reason:
            'No input or control authority while another attachment is pending');
    expect(posts, isEmpty,
        reason:
            'changing attached session must revoke A send, not send its text into B');
  });
  test('second secure write must retain the original session across attach',
      () async {
    final f = Fixture();
    await f.start();
    f.respond = (r) => r['method'] == 'session.resume'
        ? {...snapshot(), 'session_id': r['params']['session_id']}
        : {
            'admission_id': 'run',
            'ref': {
              'profile_id': 'profile',
              'session_id': r['params']['session_id']
            },
            'authority_epoch': 3,
            'execution_generation': 4,
            'status': 'started'
          };
    final secrets = GateSecrets(pauseAt: 2);
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => f.grant()), secrets,
        source: 'source', isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await f.close();
    });
    await chat.connect();
    await chat.attach('A');
    await secrets.write(
        'gateway.journal.source.B',
        jsonEncode({
          'inputId': 'input-b',
          'text': 'B held draft',
          'sessionId': 'B',
          'profileId': 'profile',
          'state': 'prepared'
        }));
    final sending = chat.send('A private draft');
    await secrets.started.future;
    final attaching = chat.attach('B');
    final writableDuringAttach = chat.connected;
    await attaching;
    secrets.gate.complete();
    Object? error;
    try {
      await sending;
    } catch (e) {
      error = e;
    }
    final posts =
        f.requests.where((r) => r['method'] == 'prompt.submit').toList();
    stdout.writeln(
        'REPRO attach during preparation: error=$error submitted=${posts.map((r) => r['params']).toList()} journalA=${await secrets.read('gateway.journal.source.A')}');
    expect(writableDuringAttach, isFalse,
        reason:
            'No input or control authority while another attachment is pending');
    expect(posts, isEmpty,
        reason:
            'changing attached session must revoke A send, not send its text into B');
  });
}

class GateSecrets extends MemorySecrets {
  GateSecrets({this.pauseAt = 1});
  final int pauseAt;
  int writes = 0;
  final started = Completer<void>(), gate = Completer<void>();
  bool first = true;
  @override
  Future<void> write(String id, String value) async {
    if (id.endsWith('.A') && ++writes == pauseAt) {
      first = false;
      started.complete();
      await gate.future;
    }
    await super.write(id, value);
  }
}

class FailingCreateController extends ChatController {
  FailingCreateController(super.store);
  bool failNextSave = false;
  @override
  Future<void> persist() async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('controlled failed creation');
    }
    await super.persist();
  }
}
