import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/gateway/session_creation.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'hermes_gateway_test.dart' show Fixture, snapshot;

class CreationSecrets extends MemorySecrets {
  bool fail = false;
  String? lastWrite;
  void Function()? beforeWrite;
  @override
  Future<void> write(String id, String value) async {
    beforeWrite?.call();
    if (fail) throw StateError('controlled storage failure');
    await super.write(id, value);
    lastWrite = id;
  }
}

void main() {
  late Fixture fixture;
  late HermesGatewayClient client;
  late CreationSecrets secrets;
  late GatewaySessionCreation creation;
  var current = true;
  setUp(() async {
    current = true;
    fixture = Fixture()
      ..capabilities.add('local-cli-create-v1')
      ..sessionCreate = {
        'sources': ['gui'],
        'parameters': ['request_id', 'source']
      };
    await fixture.start();
    fixture.respond = (_) => snapshot();
    client = HermesGatewayClient(
        grantProvider: () async => fixture.grant(),
        requestTimeout: const Duration(milliseconds: 200));
    secrets = CreationSecrets();
    creation = GatewaySessionCreation(client, secrets,
        source: 'native', isCurrent: () => current);
    await client.connect();
    await creation.load();
  });
  tearDown(() async {
    await client.dispose();
    await fixture.close();
  });

  test('create is journaled first, resolved session survives recreation',
      () async {
    fixture.respond = (_) {
      expect(secrets.lastWrite, 'gateway.creation.native');
      return snapshot();
    };
    final remote = await creation.create();
    expect(remote.id, 'chat');
    expect(creation.pending, isTrue);
    final restored = GatewaySessionCreation(client, secrets,
        source: 'native', isCurrent: () => current);
    await restored.load();
    expect(restored.sessionId, 'chat');
    await expectLater(restored.create(), throwsStateError);
    expect(fixture.requests.where((r) => r['method'] == 'session.create'),
        hasLength(1));
    await restored.dismiss();
    expect(restored.pending, isFalse);
  });
  test(
      'lost or malformed creation reply remains unknown across restart, never retried',
      () async {
    fixture.respond = (_) => {};
    await expectLater(creation.create(), throwsA(isA<Exception>()));
    final encoded = await secrets.read('gateway.creation.native');
    final restored = GatewaySessionCreation(client, secrets,
        source: 'native', isCurrent: () => current);
    await restored.load();
    expect(restored.pending, isTrue);
    expect(restored.sessionId, isNull);
    await expectLater(restored.create(), throwsStateError);
    expect(await secrets.read('gateway.creation.native'), encoded);
    expect(fixture.requests.where((r) => r['method'] == 'session.create'),
        hasLength(1));
    expect(
        fixture.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });
  test(
      'lost create ACK persists the exact intent and forbids another create after reconnect',
      () async {
    fixture.dropCreateAck = true;
    await expectLater(creation.create(), throwsA(isA<GatewayException>()));
    final evidence = await secrets.read('gateway.creation.native');
    final params = fixture.requests
        .singleWhere((r) => r['method'] == 'session.create')['params'] as Map;
    expect(jsonDecode(evidence!)['requestId'], params['request_id']);
    await client.disconnect();
    await client.connect();
    final restored = GatewaySessionCreation(client, secrets,
        source: 'native', isCurrent: () => current);
    await restored.load();
    await expectLater(restored.create(), throwsStateError);
    expect(fixture.requests.where((r) => r['method'] == 'session.create'),
        hasLength(1));
    expect(await secrets.read('gateway.creation.native'), evidence);
  });
  test('storage failure and authority loss before dispatch send no create RPC',
      () async {
    secrets.fail = true;
    await expectLater(creation.create(), throwsStateError);
    expect(fixture.requests.where((r) => r['method'] == 'session.create'),
        isEmpty);
    secrets.fail = false;
    await creation.load();
    secrets.beforeWrite = () => current = false;
    await expectLater(creation.create(), throwsStateError);
    expect(fixture.requests.where((r) => r['method'] == 'session.create'),
        isEmpty);
  });
  test('foreign profile and malformed recovery records fail closed', () async {
    await secrets.write(
        'gateway.creation.native',
        jsonEncode({
          'profileId': 'foreign',
          'requestId': 'original',
          'sessionId': 'foreign-chat'
        }));
    await expectLater(creation.load(), throwsA(isA<Exception>()));
    expect(creation.canCreate, isFalse);
    expect(creation.sessionId, isNull);
    await expectLater(creation.dismiss(), throwsStateError);
    expect(await secrets.read('gateway.creation.native'), contains('foreign'));
  });
}
