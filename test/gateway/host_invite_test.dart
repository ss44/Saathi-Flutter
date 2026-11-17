import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/host_invite.dart';
import 'package:saathi/storage/saathi_store.dart';

Map<String, dynamic> invite() => {
      'state': 'ready',
      'url': 'wss://trusted.example/api/ws',
      'protocol': 'hermes-gateway-v1',
      'protocols': ['hermes-gateway-v1', 'hermes-gateway-ticket.${'a' * 43}'],
      'ticket': 'a' * 43,
      'endpoint': {'instance_id': 'owner', 'profile_id': '/isolated/profile'},
    };
void main() {
  test(
      'expiry, source change and malformed ticket fail closed without leaking credentials',
      () async {
    var now = DateTime.utc(2026);
    final secrets = MemorySecrets();
    final vault = HostInviteVault(secrets, now: () => now);
    final source = Uri.parse('wss://trusted.example/api/ws');
    await vault.import('expiry', jsonEncode(invite()), trustedUrl: source);
    now = now.add(const Duration(seconds: 30));
    await expectLater(
        vault.consume('expiry', trustedUrl: source), throwsA(isA<Exception>()));
    await vault.import('changed', jsonEncode(invite()), trustedUrl: source);
    await expectLater(
        vault.consume('changed',
            trustedUrl: Uri.parse('wss://foreign.example/api/ws')),
        throwsA(isA<Exception>()));
    expect(await secrets.read('gateway.invite.changed'), isNull);
    for (final changed in [
      {...invite(), 'url': 'wss://foreign.example/api/ws'},
      {...invite(), 'ticket': 'not-an-official-ticket'},
      {...invite(), 'url': 'wss://trusted.example/api/ws?token=SECRET'},
    ]) {
      await expectLater(
          vault.import('bad', jsonEncode(changed), trustedUrl: source),
          throwsA(predicate((e) =>
              !e.toString().contains('SECRET') &&
              !e.toString().contains('not-an-official-ticket'))));
    }
  });
  test('imports exact attach JSON only after explicit source trust', () async {
    final secrets = MemorySecrets();
    final vault = HostInviteVault(secrets);
    final source = Uri.parse('wss://trusted.example/api/ws');
    await vault.import('connection', jsonEncode(invite()), trustedUrl: source);
    final grant = await vault.consume('connection', trustedUrl: source);
    expect(grant.url, source);
    expect(grant.expectedProfileId, '/isolated/profile');
    expect(grant.expectedInstanceId, 'owner');
    expect(await secrets.read('gateway.invite.connection'), isNull);
    await expectLater(vault.consume('connection', trustedUrl: source),
        throwsA(isA<Exception>()));
  });
}
