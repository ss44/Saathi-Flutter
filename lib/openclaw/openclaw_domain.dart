/// Bounded, native OpenClaw wire-domain helpers, not a direct-model adapter.
///
/// This module never dials, retries, stores secrets, or enables a provider. The
/// transport owner must use OS-protected credentials and an Ed25519 signer,
/// disable redirects/compression, bound frames, and revoke authority on lifecycle
/// suspension or connection/credential replacement. See OPENCLAW_EXPLORATION.md.
library;

/// An immutable original connection. Object identity, not the display ID alone,
/// binds asynchronous operations to a particular configuration generation.
class OpenClawSource {
  OpenClawSource(this.connectionId, this.url) {
    final loopback = const ['localhost', '127.0.0.1', '::1'].contains(url.host);
    if (connectionId.isEmpty ||
        !(url.scheme == 'wss' || (url.scheme == 'ws' && loopback)) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment) {
      throw ArgumentError('A credential-free secure Gateway URL is required');
    }
  }
  final String connectionId;
  final Uri url;
}

/// One genuine `models.list.models` provider/model tuple. No compatibility
/// routing aliases, agent targets or upstream credential-bearing URLs.
class OpenClawModel {
  const OpenClawModel(
      {required this.provider, required this.id, required this.name});
  final String provider;
  final String id;
  final String name;
  String get reference => '$provider/$id';

  static List<OpenClawModel> parseCatalog(Map<String, dynamic> payload) {
    final rows = payload['models'];
    if (rows is! List) {
      throw const FormatException('Missing genuine model catalog');
    }
    return List.unmodifiable(rows.map((row) {
      if (row is! Map ||
          row['id'] is! String ||
          (row['id'] as String).isEmpty ||
          row['provider'] is! String ||
          (row['provider'] as String).isEmpty) {
        throw const FormatException('Invalid provider/model catalog row');
      }
      return OpenClawModel(
          provider: row['provider'] as String,
          id: row['id'] as String,
          name: row['name'] as String? ?? row['id'] as String);
    }));
  }
}

/// Ephemeral values read from OS secret storage for this exact source/device.
/// Never save this object in preferences, transcript JSON, or diagnostics.
class OpenClawCredentials {
  const OpenClawCredentials({
    required this.deviceId,
    required this.publicKey,
    required this.token,
  });
  final String deviceId;
  final String publicKey;
  final String token;
}

/// Local observation state. ACK/admission is never a successful response.
enum OpenClawTurnState {
  awaitingAdmission,
  admitted,
  streaming,
  complete,
  failed,
  aborted,
  uncertain
}

/// Tracks ONE source/session/input/run. No automatic replay is exposed.
///
/// The caller must check its transport authority before delivering callbacks.
/// Chat delta text is a replacement snapshot, not an append-only token delta.
/// Payload seq is monotonic per run but need not be contiguous in chat-only mode;
/// the transport reports outer-frame gaps separately with [markEventGap].
class OpenClawTurn {
  OpenClawTurn(
      {required this.source, required this.sessionKey, required this.inputId});
  final OpenClawSource source;
  final String sessionKey;
  final String inputId;
  String? _runId;
  String? get runId => _runId;
  OpenClawTurnState _state = OpenClawTurnState.awaitingAdmission;
  OpenClawTurnState get state => _state;
  String _text = '';
  String get text => _text;
  int? _lastSequence;
  bool _needsHistory = false;
  bool get needsHistory => _needsHistory;

  /// An uncertain dispatch must be explicitly reconciled, never blindly retried.
  bool get canResend => false;
  bool get _terminal => const [
        OpenClawTurnState.complete,
        OpenClawTurnState.failed,
        OpenClawTurnState.aborted
      ].contains(_state);

  /// Bind the exact run from the admission receipt, not an arbitrary active run.
  void admit(String runId) {
    if (runId.isEmpty ||
        _runId != null ||
        _state != OpenClawTurnState.awaitingAdmission) {
      throw StateError('Admission is already bound or uncertain');
    }
    _runId = runId;
    _state = OpenClawTurnState.admitted;
  }

  void disconnected() {
    if (!_terminal) {
      _state = OpenClawTurnState.uncertain;
      _needsHistory = true;
    }
  }

  void markEventGap() => disconnected();

  /// Accept an already-decoded `chat` payload only for the bound owner.
  /// After a gap/disconnect, history and exact receipts must be reconciled by
  /// the transport owner; transcript text equality does not settle this input.
  bool accept(OpenClawSource eventSource, Map<String, dynamic> payload) {
    if (!identical(source, eventSource) ||
        _runId == null ||
        payload['sessionKey'] != sessionKey ||
        payload['runId'] != _runId ||
        _terminal ||
        _needsHistory) {
      return false;
    }
    final sequence = payload['seq'];
    if (sequence is! int ||
        sequence < 0 ||
        (_lastSequence != null && sequence <= _lastSequence!)) {
      return false;
    }
    final next = switch (payload['state']) {
      'delta' => OpenClawTurnState.streaming,
      'final' => OpenClawTurnState.complete,
      'error' => OpenClawTurnState.failed,
      'aborted' => OpenClawTurnState.aborted,
      _ => null,
    };
    if (next == null) return false;
    _lastSequence = sequence;
    _state = next;
    if (next == OpenClawTurnState.streaming ||
        next == OpenClawTurnState.complete) {
      final message = payload['message'];
      if (message is Map && message['content'] is List) {
        _text = (message['content'] as List)
            .whereType<Map>()
            .where(
                (block) => block['type'] == 'text' && block['text'] is String)
            .map((block) => block['text'] as String)
            .join('\n');
      }
    }
    return true;
  }
}

/// A one-way revocable lease. Create a NEW lease on resume; a boolean that can
/// become true again would resurrect requests from before suspension.
class OpenClawAuthority {
  OpenClawAuthority(this.source);
  final OpenClawSource source;
  bool _revoked = false;
  void revoke() => _revoked = true;
  void check() {
    if (_revoked) throw StateError('OpenClaw source authority was revoked');
  }

  /// Constructs protocol-4 `connect` params after challenge-bound v3 signing.
  /// The injected signer must use the same OS-stored Ed25519 identity as the
  /// credentials. It receives the EXACT UTF-8 payload; signature is base64url.
  /// This method does not dispatch. Recheck [check] immediately before dialing
  /// or writing params, and after every later transport await.
  Future<Map<String, dynamic>> prepareConnect({
    required Map<String, dynamic> challenge,
    required Future<OpenClawCredentials> Function() loadCredentials,
    required Future<String> Function(String payload) sign,
  }) async {
    check();
    final nonce = challenge['nonce'];
    final timestamp = challenge['ts'];
    if (nonce is! String ||
        nonce.isEmpty ||
        timestamp is! int ||
        timestamp < 0) {
      throw const FormatException('Invalid OpenClaw server challenge');
    }
    final credentials = await loadCredentials();
    check();
    const scopes = ['operator.read', 'operator.write'];
    final payload = [
      'v3',
      credentials.deviceId,
      'webchat',
      'webchat',
      'operator',
      scopes.join(','),
      '$timestamp',
      credentials.token,
      nonce,
      'flutter',
      ''
    ].join('|');
    final signature = await sign(payload);
    check();
    return {
      'minProtocol': 4,
      'maxProtocol': 4,
      'client': {
        'id': 'webchat',
        'mode': 'webchat',
        'platform': 'flutter',
        'version': 'saathi'
      },
      'role': 'operator',
      'scopes': scopes,
      'caps': ['chat-only-assistant-text'],
      'auth': {'token': credentials.token},
      'device': {
        'id': credentials.deviceId,
        'publicKey': credentials.publicKey,
        'signature': signature,
        'signedAt': timestamp,
        'nonce': nonce
      },
    };
  }
}
