import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../storage/saathi_store.dart';
import 'openclaw_domain.dart';

/// Sensitive device identity plus its operator grant. The private key is PKCS8
/// base64url supplied/verified by the platform Ed25519 signer, not generated here.
/// This record deliberately has no public JSON/history serialization API.
class OpenClawSecretRecord {
  const OpenClawSecretRecord(
      {required this.deviceId,
      required this.publicKey,
      required this.privateKeyPkcs8,
      required this.deviceToken,
      required this.scopes});
  final String deviceId;
  final String publicKey;
  final String privateKeyPkcs8;
  final String deviceToken;
  final List<String> scopes;

  /// Current socket grants may be narrower than an unchanged stored token grant.
  /// Only a newly issued/rotated token replaces its approved scope metadata.
  OpenClawSecretRecord withHelloToken(String token, List<String> liveScopes) =>
      OpenClawSecretRecord(
          deviceId: deviceId,
          publicKey: publicKey,
          privateKeyPkcs8: privateKeyPkcs8,
          deviceToken: token,
          scopes:
              List.unmodifiable(token == deviceToken ? scopes : liveScopes));
}

/// Stores device key AND token together in OS secret storage, separately from
/// preferences/history and from the direct-provider API-key slot. Production
/// defaults to the app's existing Keychain/Keystore-backed [PlatformSecrets].
/// Injected stores are for controlled tests; never pass a preference-backed store.
///
/// Slots bind exact connection ID, Gateway URL, client ID and operator role.
/// Revocation discards delayed reads and prevents dispatch from stale material.
/// A write already in progress can finish in its ORIGINAL slot; callers serialize
/// same-source credential replacement and must not reuse revoked authority.
class OpenClawSecrets {
  const OpenClawSecrets([this._storage = const PlatformSecrets()]);
  final SecretStore _storage;
  String _slot(OpenClawSource source) =>
      'openclaw.device.v1.${sha256.convert(utf8.encode(jsonEncode([
            source.connectionId,
            source.url.toString(),
            'webchat',
            'operator'
          ])))}';

  Future<OpenClawSecretRecord?> read(OpenClawAuthority authority) async {
    authority.check();
    final raw = await _storage.read(_slot(authority.source));
    authority.check();
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['schema'] != 1 ||
        decoded['deviceId'] is! String ||
        decoded['publicKey'] is! String ||
        decoded['privateKeyPkcs8'] is! String ||
        decoded['deviceToken'] is! String ||
        decoded['scopes'] is! List ||
        (decoded['scopes'] as List).any((s) => s is! String)) {
      throw const FormatException('Invalid protected OpenClaw device record');
    }
    return OpenClawSecretRecord(
        deviceId: decoded['deviceId'] as String,
        publicKey: decoded['publicKey'] as String,
        privateKeyPkcs8: decoded['privateKeyPkcs8'] as String,
        deviceToken: decoded['deviceToken'] as String,
        scopes: List<String>.unmodifiable(decoded['scopes'] as List));
  }

  Future<void> save(
      OpenClawAuthority authority, OpenClawSecretRecord record) async {
    authority.check();
    await _storage.write(
        _slot(authority.source),
        jsonEncode({
          'schema': 1,
          'deviceId': record.deviceId,
          'publicKey': record.publicKey,
          'privateKeyPkcs8': record.privateKeyPkcs8,
          'deviceToken': record.deviceToken,
          'scopes': record.scopes,
        }));
    authority.check();
  }

  Future<void> delete(OpenClawAuthority authority) async {
    authority.check();
    await _storage.delete(_slot(authority.source));
    authority.check();
  }
}
