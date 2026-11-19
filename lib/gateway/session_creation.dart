import 'dart:convert';
import 'dart:math';
import '../storage/saathi_store.dart';
import 'hermes_gateway.dart';

/// Durable creation evidence, separate from prompt admission and its FIFO.
/// Unknown creation is never retried: a fresh grant does not prove the same
/// principal. Browse the host before explicitly dismissing an unknown intent.
class GatewaySessionCreation {
  GatewaySessionCreation(this.client, this.secrets,
      {required this.source, required this.isCurrent});

  final HermesGatewayClient client;
  final SecretStore secrets;
  final String source;
  final bool Function() isCurrent;
  String get _key => 'gateway.creation.$source';
  Map<String, dynamic>? _record;
  bool _loaded = false, working = false;
  String? problem;
  bool get pending => _record != null;
  String? get sessionId => _record?['sessionId'] as String?;
  bool get canCreate =>
      _loaded && !pending && !working && isCurrent() && client.canCreateSession;

  /// Read only the original profile's evidence; malformed/foreign data is kept.
  Future<void> load() async {
    if (working) throw StateError('Creation operation in progress');
    _loaded = false;
    _record = null;
    problem =
        'Creation recovery could not be read for this profile. New creation is disabled; existing sessions can still be opened. The saved evidence has not been changed.';
    final encoded = await secrets.read(_key);
    if (!isCurrent()) throw StateError('Gateway source revoked');
    if (encoded != null) {
      if (encoded.length > 16384) throw const FormatException();
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['profileId'] != client.profileId ||
          value['requestId'] is! String ||
          (value['requestId'] as String).isEmpty ||
          (value['requestId'] as String).length > 256 ||
          (value['sessionId'] != null &&
              (value['sessionId'] is! String ||
                  (value['sessionId'] as String).isEmpty))) {
        throw const GatewayException(
            'Creation evidence needs its original profile');
      }
      _record = value;
    }
    _loaded = true;
    problem = null;
  }

  /// Creates an empty native conversation using the host's existing defaults.
  /// Persists uncertainty before RPC; never sends a prompt or a copied history.
  Future<GatewaySession> create({bool Function()? isAuthorized}) async {
    if (!canCreate) throw StateError('Creation unavailable or needs review');
    final profile = client.profileId!;
    bool valid() =>
        isCurrent() &&
        client.profileId == profile &&
        (isAuthorized?.call() ?? true);
    final record = <String, dynamic>{
      'profileId': profile,
      'requestId': List.generate(
          24,
          (_) => Random.secure()
              .nextInt(256)
              .toRadixString(16)
              .padLeft(2, '0')).join(),
    };
    working = true;
    try {
      await secrets.write(_key, jsonEncode(record));
      _record = record;
      if (!valid()) throw StateError('Gateway source revoked');
      final remote =
          await client.createSession(requestId: record['requestId'] as String);
      // Retain the result even if the caller navigated away. Adopting it is a
      // separate explicit attachment, not permission to change the active chat.
      _record = {...record, 'sessionId': remote.id};
      await secrets.write(_key, jsonEncode(_record));
      if (!valid()) throw StateError('Gateway source revoked');
      return remote;
    } catch (_) {
      // A failed secure write may have landed. Re-read before permitting any
      // further creation; never infer absence from a failed Future alone.
      _loaded = false;
      rethrow;
    } finally {
      working = false;
    }
  }

  /// Call after saved attachment, or explicit consent to dismiss uncertainty.
  /// This does not delete a server session or undo a possibly successful create.
  Future<void> dismiss() async {
    if (!_loaded || working || !isCurrent()) {
      throw StateError('Creation evidence unavailable');
    }
    working = true;
    try {
      final stored = await secrets.read(_key);
      if (!isCurrent() ||
          stored != (_record == null ? null : jsonEncode(_record))) {
        throw StateError('Creation evidence changed');
      }
      await secrets.delete(_key);
      _record = null;
    } finally {
      working = false;
    }
  }
}
