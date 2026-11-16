import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/openclaw/openclaw_domain.dart';
import 'package:saathi/openclaw/openclaw_secrets.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
  test('delayed protected read is discarded when its source is revoked',
      () async {
    final store = DelayedSecrets();
    final vault = OpenClawSecrets(store);
    final lease =
        OpenClawAuthority(OpenClawSource('a', Uri.parse('wss://one.test')));
    final read = vault.read(lease);
    final rejected = expectLater(read, throwsStateError);
    lease.revoke();
    store.pending.complete(null);
    await rejected;
  });
  test('corrupt protected records and denied writes do not silently downgrade',
      () async {
    final store = DelayedSecrets();
    final vault = OpenClawSecrets(store);
    final lease =
        OpenClawAuthority(OpenClawSource('a', Uri.parse('wss://one.test')));
    final read = vault.read(lease);
    store.pending.complete('{"schema":1}');
    await expectLater(read, throwsFormatException);
    const record = OpenClawSecretRecord(
        deviceId: 'd',
        publicKey: 'p',
        privateKeyPkcs8: 'k',
        deviceToken: 't',
        scopes: []);
    await expectLater(vault.save(lease, record), throwsStateError);
  });
  test('device material uses source-bound OS secret slots, never preferences',
      () async {
    final backing = MemorySecrets();
    final vault = OpenClawSecrets(backing);
    final first = OpenClawAuthority(
        OpenClawSource('connection', Uri.parse('wss://one.test')));
    final second = OpenClawAuthority(
        OpenClawSource('connection', Uri.parse('wss://two.test')));
    const record = OpenClawSecretRecord(
        deviceId: 'device',
        publicKey: 'public',
        privateKeyPkcs8: 'private',
        deviceToken: 'token',
        scopes: ['operator.read', 'operator.write']);
    await vault.save(first, record);
    expect((await vault.read(first))?.privateKeyPkcs8, 'private');
    expect((await vault.read(first))?.deviceToken, 'token');
    expect(await vault.read(second), isNull);
    await vault.delete(first);
    expect(await vault.read(first), isNull);
    first.revoke();
    await expectLater(vault.save(first, record), throwsStateError);
  });
  test('same token preserves its approved scopes; a new token uses new grants',
      () {
    const record = OpenClawSecretRecord(
        deviceId: 'device',
        publicKey: 'public',
        privateKeyPkcs8: 'private',
        deviceToken: 'token',
        scopes: ['operator.read', 'operator.write']);
    final narrower = record.withHelloToken('token', ['operator.read']);
    expect(narrower.scopes, ['operator.read', 'operator.write']);
    final rotated = record.withHelloToken('new-token', ['operator.read']);
    expect(rotated.scopes, ['operator.read']);
    expect(rotated.privateKeyPkcs8, 'private');
  });
}

class DelayedSecrets implements SecretStore {
  final pending = Completer<String?>();
  @override
  Future<String?> read(String id) => pending.future;
  @override
  Future<void> write(String id, String value) async =>
      throw StateError('protected storage unavailable');
  @override
  Future<void> delete(String id) async {}
}
