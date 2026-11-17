/// Explicit host-issued `hermes gateway attach --json` import. No login broker.
library;

import 'dart:convert';
import '../storage/saathi_store.dart';
import 'hermes_gateway.dart';

/// Stores the complete credential only in OS secure storage in production.
/// Deletes BEFORE dialing: a failed upgrade can have consumed the one-use ticket.
class HostInviteVault {
  HostInviteVault(this.secrets, {DateTime Function()? now})
      : now = now ?? DateTime.now;
  final SecretStore secrets;
  final DateTime Function() now;

  static Uri trustedSource(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'wss' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/api/ws') {
      throw const GatewayException(
          'Enter the trusted host’s WSS /api/ws address');
    }
    return uri;
  }

  GatewayGrant _decode(String text, Uri trustedUrl) {
    try {
      trustedSource(trustedUrl.toString());
      if (text.length > 32768) throw const FormatException();
      final value = jsonDecode(text) as Map<String, dynamic>;
      final endpoint = value['endpoint'] as Map;
      final ticket = value['ticket'];
      final protocols = (value['protocols'] as List).cast<String>();
      if (value['state'] != 'ready' ||
          value['url'] != trustedUrl.toString() ||
          value['protocol'] != 'hermes-gateway-v1' ||
          ticket is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(ticket) ||
          protocols.length != 2 ||
          protocols[0] != 'hermes-gateway-v1' ||
          protocols[1] != 'hermes-gateway-ticket.$ticket' ||
          endpoint['profile_id'] is! String ||
          (endpoint['profile_id'] as String).isEmpty ||
          endpoint['instance_id'] is! String ||
          (endpoint['instance_id'] as String).isEmpty) {
        throw const FormatException();
      }
      return GatewayGrant(
          url: trustedUrl,
          protocols: protocols,
          expectedProfileId: endpoint['profile_id'] as String,
          expectedInstanceId: endpoint['instance_id'] as String);
    } catch (_) {
      throw const GatewayException(
          'Invalid host invite or trusted source mismatch');
    }
  }

  Future<void> import(String id, String text, {required Uri trustedUrl}) async {
    _decode(text, trustedUrl);
    // Official attach has no wall-clock expiry field. This is an additional
    // local maximum, NOT an extension of the host's 30-second mint-time expiry.
    await secrets.write(
        'gateway.invite.$id',
        jsonEncode({
          'invite': text,
          'source': trustedUrl.toString(),
          'expires':
              now().add(const Duration(seconds: 30)).millisecondsSinceEpoch,
        }));
  }

  Future<GatewayGrant> consume(String id, {required Uri trustedUrl}) async {
    final key = 'gateway.invite.$id';
    final encoded = await secrets.read(key);
    if (encoded == null) {
      throw const GatewayException('Import a fresh host invite to connect');
    }
    await secrets.delete(key);
    try {
      final stored = jsonDecode(encoded) as Map<String, dynamic>;
      if (stored['source'] != trustedUrl.toString() ||
          now().millisecondsSinceEpoch >= (stored['expires'] as int)) {
        throw const FormatException();
      }
      return _decode(stored['invite'] as String, trustedUrl);
    } catch (_) {
      throw const GatewayException(
          'Invite expired or source changed. Import a fresh host invite');
    }
  }
}
