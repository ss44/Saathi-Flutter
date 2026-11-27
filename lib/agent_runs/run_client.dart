import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../storage/saathi_store.dart';
import '../core/saathi_core.dart' show ChatPhoto;
import '../agent_controls/agent_controls.dart';

String runIdentity() => List.generate(32,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
    .join();

enum RunState {
  unknown,
  queued,
  running,
  stopping,
  waitingForApproval,
  completed,
  failed,
  cancelled,
  interrupted,
  unrecognized
}

class RunSnapshot {
  RunSnapshot(Map<String, dynamic> data) : data = Map.unmodifiable(data);
  final Map<String, dynamic> data;
  String get status =>
      data['status'] is String ? data['status'] as String : 'unknown';
  String? get runId =>
      data['run_id'] is String ? data['run_id'] as String : null;
  String? get admissionId =>
      data['admission_id'] is String ? data['admission_id'] as String : null;
  int? get generation => data['execution_generation'] is int
      ? data['execution_generation'] as int
      : null;
  List<Map<String, dynamic>> get pendingControls =>
      (data['pending_controls'] is List ? data['pending_controls'] as List : [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  String get output => data['output'] is String ? data['output'] as String : '';
  RunState get state => switch (status) {
        'unknown' => RunState.unknown,
        'queued' => RunState.queued,
        'started' || 'running' => RunState.running,
        'stopping' => RunState.stopping,
        'waiting_for_approval' => RunState.waitingForApproval,
        'completed' => RunState.completed,
        'failed' => RunState.failed,
        'cancelled' => RunState.cancelled,
        'interrupted' => RunState.interrupted,
        _ => RunState.unrecognized,
      };
  bool get terminal => [
        RunState.completed,
        RunState.failed,
        RunState.cancelled,
        RunState.interrupted
      ].contains(state);
}

// A photo turn uses a single user message with an optional caption and inline
// image_url parts. A plain turn keeps the original string payload.
(String, List<ChatPhoto>) _readRunInput(Object? value) {
  if (value is String) return (value, const []);
  Never invalid() => throw const FormatException('Invalid run input');
  if (value is! List || value.length != 1) invalid();
  final message = value.single;
  if (message is! Map || message.length != 2 || message['role'] != 'user') {
    invalid();
  }
  final parts = message['content'];
  if (parts is! List ||
      parts.isEmpty ||
      parts.length > ChatPhoto.maxCount + 1) {
    invalid();
  }
  var caption = '';
  final urls = <String>[];
  final data = <String>[];
  for (final (index, part) in parts.indexed) {
    if (part is! Map || part.length != 2) invalid();
    if (index == 0 && part['type'] == 'text' && part['text'] is String) {
      caption = part['text'] as String;
      if (caption.length > 256 * 1024) invalid();
      continue;
    }
    final image = part['image_url'];
    final url = image is Map && image.length == 1 ? image['url'] : null;
    if (part['type'] != 'image_url' || url is! String) invalid();
    final separator = url.indexOf(',');
    if (separator < 0 || separator > 32) invalid();
    urls.add(url);
    data.add(url.substring(separator + 1));
  }
  if (urls.isEmpty) invalid();
  final photos = ChatPhoto.decodeList(data);
  for (final (index, photo) in photos.indexed) {
    if (photo.dataUrl != urls[index]) invalid();
  }
  return (caption, List.unmodifiable(photos));
}

/// Entire bounded journal lives in OS secure storage, including the exact bytes
/// needed to recover a lost admission ACK. No bearer key is copied into it.
class RunOperation {
  RunOperation(this.data)
      : _originalLocal = data['local'],
        _originalKey = data['key'];
  final Map<String, dynamic> data;
  final Object? _originalLocal, _originalKey;
  String get key => data['key'] as String;
  String get payload => data['payload'] as String;
  String get sessionId => data['session'] as String;
  String get localId => data['local'] as String;
  String? _parsedPayload;
  late (String, List<ChatPhoto>) _parsedInput;

  (String, List<ChatPhoto>) get _input {
    final body = payload;
    if (_parsedPayload != body) {
      _readInput(body, (jsonDecode(body) as Map)['input']);
    }
    return _parsedInput;
  }

  void _readInput(String body, Object? input) {
    if (_parsedPayload == body) return;
    _parsedInput = _readRunInput(input);
    _parsedPayload = body;
  }

  String get input => _input.$1;
  List<ChatPhoto> get photos => _input.$2;
  String? get runId => data['run'] as String?;
  bool get committed => data['committed'] == true;
  RunSnapshot get snapshot =>
      RunSnapshot(Map<String, dynamic>.from(data['snapshot'] as Map? ?? {}));
  bool get replayExpired =>
      DateTime.now().difference(DateTime.parse(data['created'] as String)) >=
      const Duration(hours: 24);
}

class PreparedRunRevoked extends StateError {
  PreparedRunRevoked(this.operation) : super('Prepared run permission revoked');
  final RunOperation operation;
}

/// Validated page returned by `GET /api/sessions/{session_id}/messages` under
/// an operation's bound RunClient origin and credential scope.
class RunHistoryPage {
  const RunHistoryPage({
    required this.sessionId,
    required this.messages,
    required this.pagination,
  });

  final String sessionId;
  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> pagination;
}

class RunLedger {
  RunLedger(this.secrets);
  final SecretStore secrets;
  static const _textLimit = 256 * 1024;
  static const _photoLimit = 2 * 1024 * 1024;

  Future<RunOperation?> load(String local) async {
    final raw = await secrets.read('run.v1.$local');
    if (raw == null) return null;
    final bytes = utf8.encode(raw).length;
    if (bytes > _photoLimit) {
      throw const FormatException('Oversized run journal');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid run journal');
    }
    for (final key in [
      'key',
      'payload',
      'session',
      'local',
      'scope',
      'origin',
      'created'
    ]) {
      if (decoded[key] is! String || (decoded[key] as String).isEmpty) {
        throw const FormatException('Invalid run journal field');
      }
    }
    final payload = jsonDecode(decoded['payload'] as String);
    if (decoded['local'] != local ||
        DateTime.tryParse(decoded['created'] as String) == null ||
        payload is! Map ||
        payload['session_id'] != decoded['session'] ||
        (decoded['run'] != null && decoded['run'] is! String) ||
        (decoded['authorityEpoch'] != null &&
            decoded['authorityEpoch'] is! String) ||
        (decoded['snapshot'] != null &&
            decoded['snapshot'] is! Map<String, dynamic>)) {
      throw const FormatException('Invalid run journal identity');
    }
    final op = RunOperation(decoded);
    _validate(op, local);
    if (op.photos.isEmpty && bytes > _textLimit) {
      throw const FormatException('Oversized run journal');
    }
    return op;
  }

  static void _validate(RunOperation op, String local) {
    final data = op.data;
    Never invalid() =>
        throw const FormatException('Invalid run journal schema');
    bool identity(dynamic value) =>
        value is String &&
        value.length <= 256 &&
        RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value);
    for (final field in ['key', 'scope']) {
      if (data[field] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(data[field] as String)) {
        invalid();
      }
    }
    if (data['local'] != local ||
        !identity(local) ||
        !identity(data['session']) ||
        (data['run'] != null && !identity(data['run'])) ||
        (data['authorityEpoch'] != null && !identity(data['authorityEpoch']))) {
      invalid();
    }
    final created = data['created'];
    if (created is! String ||
        !RegExp(r'^\d{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.\d{1,6})?Z$')
            .hasMatch(created) ||
        DateTime.tryParse(created) == null ||
        DateTime.parse(created).toIso8601String().substring(0, 19) !=
            created.substring(0, 19)) {
      invalid();
    }
    final origin = data['origin'];
    if (origin is! String || origin.trim().isEmpty) invalid();
    try {
      RunClient(origin, '').close();
    } on ArgumentError {
      invalid();
    }
    for (final flag in [
      'attempted',
      'committed',
      'alertClaimed',
      'journalDirty'
    ]) {
      if (data.containsKey(flag) && data[flag] is! bool) invalid();
    }
    final payload = data['payload'];
    if (payload is! String) invalid();
    final body = jsonDecode(payload);
    if (body is! Map || body['session_id'] != data['session']) invalid();
    // Decode the exact sent bytes and cache the bounded, typed input on the
    // operation for previews, recovery matching, and subsequent status saves.
    op._readInput(payload, body['input']);
    if ((data.containsKey('capturedInstructions') &&
            (data['capturedInstructions'] is! String ||
                (data['capturedInstructions'] as String).length > 16000)) ||
        (data.containsKey('personaId') &&
            (data['personaId'] is! String ||
                (data['personaId'] as String).isEmpty ||
                (data['personaId'] as String).length > 256)) ||
        (data.containsKey('personaRevision') &&
            (data['personaRevision'] is! int ||
                (data['personaRevision'] as int) < 0 ||
                (data['personaRevision'] as int) > 2147483647))) {
      invalid();
    }
    final snapshot = data['snapshot'];
    if (snapshot != null) {
      if (snapshot is! Map<String, dynamic>) invalid();
      _validateSnapshot(snapshot);
      if (snapshot['run_id'] != null && snapshot['run_id'] != data['run']) {
        invalid();
      }
    }
  }

  static void _validateSnapshot(Map<String, dynamic> snapshot) {
    if (snapshot['status'] == 'completed' && snapshot['output'] is! String) {
      throw const FormatException('Completed run requires explicit output');
    }
    for (final field in ['status', 'output', 'run_id', 'admission_id']) {
      if (snapshot.containsKey(field) && snapshot[field] is! String) {
        throw const FormatException('Invalid run snapshot field');
      }
    }
    for (final field in ['run_id', 'admission_id']) {
      if (snapshot.containsKey(field) &&
          !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(snapshot[field] as String)) {
        throw const FormatException('Invalid snapshot identity');
      }
    }
    if (snapshot.containsKey('execution_generation') &&
        (snapshot['execution_generation'] is! int ||
            (snapshot['execution_generation'] as int) < 0)) {
      throw const FormatException('Invalid run generation');
    }
    if (snapshot.containsKey('pending_controls')) {
      final controls = snapshot['pending_controls'];
      if (controls is! List ||
          controls.any((v) => v is! Map<String, dynamic>)) {
        throw const FormatException('Invalid run controls');
      }
    }
  }

  // SecretStore has no compare-and-swap: this serializes only this process,
  // across ledger instances sharing the exact same store object.
  static final _tails = Expando<Future<void>>();

  Future<void> save(RunOperation op,
      {bool Function()? isCurrent,
      String? previousKey,
      void Function()? onWritten}) async {
    final before = _tails[secrets] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[secrets] = done.future;
    try {
      await before;
      void check() {
        if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
      }

      check();
      if (op.data['local'] != op._originalLocal ||
          op.data['key'] != op._originalKey) {
        throw StateError('Run identity is immutable');
      }
      _validate(op, op.localId);
      final current = await load(op.localId);
      check();
      if (current != null) {
        if (current.key != op.key) {
          if (previousKey != current.key ||
              !current.committed ||
              !current.snapshot.terminal ||
              current.data['journalDirty'] == true) {
            throw StateError('Uncommitted or stale run predecessor');
          }
        } else {
          for (final field in [
            'key',
            'payload',
            'session',
            'local',
            'scope',
            'origin',
            'created',
            'authorityEpoch',
            'capturedInstructions',
            'personaId',
            'personaRevision',
          ]) {
            if (current.data[field] != op.data[field]) {
              throw StateError('Run identity is immutable');
            }
          }
          if (current.runId != null && current.runId != op.runId) {
            throw StateError('Run identity is immutable');
          }
          if (current.snapshot.terminal) {
            op.data['snapshot'] = current.data['snapshot'];
          }
          for (final flag in ['committed', 'alertClaimed', 'attempted']) {
            if (current.data[flag] == true) op.data[flag] = true;
          }
        }
      } else if (previousKey != null) {
        throw StateError('Missing run predecessor');
      }
      final raw = jsonEncode(op.data);
      final limit = op.photos.isEmpty ? _textLimit : _photoLimit;
      if (utf8.encode(raw).length > limit) {
        throw StateError('Run journal size limit');
      }
      check();
      await secrets.write('run.v1.${op.localId}', raw);
      onWritten?.call();
      check();
    } finally {
      done.complete();
    }
  }
}

typedef RunClientFactory = RunClient Function(String root, String key);

class RunClient {
  RunClient(String root, this._key, {http.Client? client})
      : _client = client ?? http.Client(),
        _owns = client == null {
    var normalized = root.replaceFirst(RegExp(r'/+$'), '');
    if (normalized.endsWith('/v1')) {
      normalized = normalized.substring(0, normalized.length - 3);
    }
    base = Uri.parse(normalized);
    if (!['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.scheme == 'http' &&
            !['127.0.0.1', 'localhost', '::1', '[::1]'].contains(base.host)) ||
        !RegExp(r'^(/p/[a-zA-Z0-9_-]+)?$').hasMatch(base.path)) {
      throw ArgumentError('Unsafe Runs origin/profile');
    }
  }
  late final Uri base;
  final String _key;
  final http.Client _client;
  final bool _owns;
  Map<String, dynamic> capabilities = {};
  String get scope =>
      sha256.convert(utf8.encode('${base.toString()}\u0000$_key')).toString();
  void close() {
    if (_owns) _client.close();
  }

  Future<(int, Map<String, dynamic>, Map<String, String>)> _request(
      String method, String path,
      {String? body,
      String? key,
      bool discovery = false,
      int maxResponseBytes = 1024 * 1024}) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(method, Uri.parse('$base$path'),
        abortTrigger: abort.future)
      ..followRedirects = false;
    request.headers.addAll({
      'authorization': 'Bearer $_key',
      'content-type': 'application/json',
      if (key != null) 'Idempotency-Key': key
    });
    if (body != null) request.body = body;
    try {
      return await (() async {
        final response = await _client.send(request);
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length > maxResponseBytes) {
            throw StateError('Run response too large');
          }
        }
        return (
          response.statusCode,
          discovery && response.statusCode == 404
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(
                  jsonDecode(utf8.decode(bytes)) as Map),
          response.headers
        );
      })()
          .timeout(const Duration(seconds: 20));
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  bool _endpoint(String name, String method, String path) {
    final endpoints = capabilities['endpoints'];
    final e = endpoints is Map ? endpoints[name] : null;
    return e is Map && e['method'] == method && e['path'] == path;
  }

  bool get eventsSupported =>
      capabilities['features'] is Map &&
      (capabilities['features'] as Map)['run_events_sse'] == true &&
      _endpoint('run_events', 'GET', '/v1/runs/{run_id}/events');

  Future<bool> discover() async {
    final (code, data, _) =
        await _request('GET', '/v1/capabilities', discovery: true);
    capabilities = data;
    if (code == 404) return false;
    if (code != 200) throw StateError('Run discovery unavailable');
    return _runsSupported;
  }

  bool get _runsSupported {
    final f = capabilities['features'];
    if (f is! Map) return false;
    return f['run_submission'] == true &&
        f['run_status'] == true &&
        f['runs_idempotency'] is Map &&
        (f['runs_idempotency'] as Map)['supported'] != false &&
        _endpoint('runs', 'POST', '/v1/runs') &&
        _endpoint('run_status', 'GET', '/v1/runs/{run_id}');
  }

  /// Inline structured input follows the official Hermes Runs implementation.
  /// Compatible-looking proxies must identify as Hermes and advertise Runs.
  bool get photosSupported =>
      capabilities['object'] == 'hermes.api_server.capabilities' &&
      capabilities['platform'] == 'hermes-agent' &&
      _runsSupported;

  void bind(RunOperation op) {
    if (op.data['scope'] != scope || op.data['origin'] != base.toString()) {
      throw StateError('Original connection authority required');
    }
  }

  Future<RunOperation> prepare(RunLedger ledger,
      {required String local,
      String? existingSessionId,
      required String input,
      List<ChatPhoto> photos = const [],
      required String model,
      String? provider,
      required String instructions,
      String? personaId,
      int personaRevision = 0,
      required List<Map<String, dynamic>> history,
      String? authorityEpoch,
      bool Function()? isCurrent,
      RunOperation? previous}) async {
    if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    if (previous != null) bind(previous);
    if (photos.isNotEmpty &&
        (!photosSupported || !ChatPhoto.fitsDraft(photos))) {
      throw StateError('Hermes Runs photo input is unavailable');
    }
    final op = RunOperation({
      if (authorityEpoch != null) 'authorityEpoch': authorityEpoch,
      'local': local,
      'capturedInstructions': instructions,
      if (personaId != null) 'personaId': personaId,
      'personaRevision': personaRevision,
      'session':
          previous?.sessionId ?? existingSessionId ?? 'saathi_${runIdentity()}',
      'key': runIdentity(),
      'scope': scope,
      'origin': base.toString(),
      'created': DateTime.now().toUtc().toIso8601String()
    });
    op.data['payload'] = jsonEncode({
      'input': photos.isEmpty
          ? input
          : [
              {
                'role': 'user',
                'content': [
                  if (input.isNotEmpty) {'type': 'text', 'text': input},
                  for (final photo in photos)
                    {
                      'type': 'image_url',
                      'image_url': {'url': photo.dataUrl}
                    },
                ],
              },
            ],
      'session_id': op.sessionId,
      if (existingSessionId == null) 'model': model,
      if (existingSessionId == null && provider != null) 'provider': provider,
      if (existingSessionId == null && instructions.isNotEmpty)
        'instructions': instructions,
      if (existingSessionId == null && previous == null && history.isNotEmpty)
        'conversation_history': history
    });
    if (previous?.data['journalDirty'] == true) {
      throw StateError('Run predecessor is not durable');
    }
    var written = false;
    try {
      await ledger.save(op,
          isCurrent: isCurrent,
          previousKey: previous?.key,
          onWritten: () => written = true);
    } catch (_) {
      // Revocation cannot cancel an already-started durable identity write.
      if (written) throw PreparedRunRevoked(op);
      rethrow;
    }
    return op;
  }

  Future<void> submit(RunOperation op, RunLedger ledger,
      {bool Function()? isCurrent}) async {
    void check() {
      if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    }

    check();
    bind(op);
    if (op.photos.isNotEmpty && !photosSupported) {
      throw StateError('Hermes Runs photo input is unavailable');
    }
    if (op.replayExpired) {
      throw StateError('Replay window expired; do not resubmit');
    }
    // Written before every transmission. An exception never permits chat fallback.
    op.data['attempted'] = true;
    await ledger.save(op, isCurrent: isCurrent);
    check();
    final (code, data, headers) =
        await _request('POST', '/v1/runs', body: op.payload, key: op.key);
    check();
    final error = data['error'];
    final type = error is Map ? error['code'] ?? error['type'] : data['code'];
    final queued = code == 503 &&
        type == 'admission_queued' &&
        headers['x-should-retry'] == 'false';
    if (code != 202 && !queued) {
      op.data['snapshot'] = {'status': 'unknown'};
      op.data['refusal'] = type;
      await ledger.save(op, isCurrent: isCurrent);
      throw StateError(
          'Run admission not confirmed. Reconnect with the same operation.');
    }
    RunLedger._validateSnapshot(data);
    if (data['run_id'] is String) op.data['run'] = data['run_id'];
    // Admission is a receipt, never authoritative terminal execution state.
    op.data['snapshot'] = {
      ...data,
      if (queued || RunSnapshot(data).terminal) 'status': 'queued'
    };
    await ledger.save(op, isCurrent: isCurrent);
  }

  String _id(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw StateError('Invalid run identity');
    }
    return id;
  }

  Future<RunSnapshot> status(RunOperation op, RunLedger ledger,
      {bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    bind(op);
    final (code, data, _) = await _request('GET', '/v1/runs/${_id(op.runId!)}');
    if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    if (code != 200 ||
        data['run_id'] != op.runId ||
        (data.containsKey('session_id') &&
            data['session_id'] != op.sessionId)) {
      throw StateError('Run status unavailable');
    }
    // Only a recognized, explicit lifecycle observation can replace the last
    // valid snapshot. Missing status is not the server's explicit unknown state.
    if (data['status'] is! String ||
        RunSnapshot(data).state == RunState.unrecognized) {
      throw const FormatException('Invalid run status observation');
    }
    RunLedger._validateSnapshot(data);
    // A terminal poll snapshot cannot be rolled back by delayed status updates.
    if (!op.snapshot.terminal) op.data['snapshot'] = data;
    try {
      await ledger.save(op, isCurrent: isCurrent);
    } catch (_) {
      // A durability failure must not discard the answer already received.
      op.data['journalDirty'] = true;
    }
    if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    return op.snapshot;
  }

  /// Read-only session history fetch bound to [op]'s original authority.
  /// Used to refresh and match a lost admission receipt without resending.
  Future<RunHistoryPage> sessionMessages(
    RunOperation op, {
    int limit = 100,
    int offset = 0,
    bool matchInlinePhotos = false,
    bool Function()? isCurrent,
  }) async {
    if (limit < 1 || limit > 100 || offset < 0) {
      throw ArgumentError('Invalid message pagination');
    }
    if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    bind(op);
    final query = Uri(queryParameters: {
      'limit': '$limit',
      'offset': '$offset',
      'order': 'oldest',
      'include_compacted': 'false',
      'inline_images': matchInlinePhotos.toString(),
    }).query;
    final (code, data, _) = await _request(
      'GET',
      '/api/sessions/${Uri.encodeComponent(_id(op.sessionId))}/messages?$query',
      maxResponseBytes: matchInlinePhotos ? 2 * 1024 * 1024 : 1024 * 1024,
    );
    if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    if (code != 200) throw StateError('Session history unavailable');
    final sessionId = data['session_id'];
    if (sessionId != null && sessionId != op.sessionId) {
      throw StateError('Session identity mismatch');
    }
    final rawList = data['data'];
    if (rawList is! List || rawList.any((row) => row is! Map)) {
      throw const FormatException('Invalid session history response');
    }
    final paginationRaw = data['pagination'];
    if (paginationRaw != null && paginationRaw is! Map) {
      throw const FormatException('Invalid session history pagination');
    }
    final pagination = paginationRaw is Map
        ? Map<String, dynamic>.from(paginationRaw)
        : const <String, dynamic>{};
    final returned = pagination['returned'] as int? ?? rawList.length;
    final pageLimit = pagination['limit'] as int? ?? limit;
    if ((pagination['offset'] ?? offset) != offset ||
        returned != rawList.length ||
        pageLimit <= 0 ||
        pageLimit > 100 ||
        returned > pageLimit) {
      throw const FormatException('Invalid session history pagination');
    }
    return RunHistoryPage(
      sessionId: sessionId is String ? sessionId : op.sessionId,
      messages: [
        for (final row in rawList) Map<String, dynamic>.from(row as Map),
      ],
      pagination: pagination,
    );
  }

  bool get canResolveUnknown =>
      capabilities['features'] is Map &&
      (capabilities['features'] as Map)['run_unknown_resolution'] == true &&
      _endpoint('run_unknown_resolution', 'POST',
          '/v1/runs/{run_id}/resolve-unknown');

  bool get canSteer =>
      capabilities['features'] is Map &&
      (capabilities['features'] as Map)['run_steer'] == true &&
      _endpoint('run_steer', 'POST', '/v1/runs/{run_id}/steer');
  bool get canStop =>
      capabilities['features'] is Map &&
      (capabilities['features'] as Map)['run_stop'] == true &&
      _endpoint('run_stop', 'POST', '/v1/runs/{run_id}/stop');

  /// One control attempt. A timeout may have delivered guidance; never retry it
  /// or convert it to another inference. Stop ACK is not terminal cancellation.
  Future<void> control(RunOperation op,
      {String? guidance, required bool Function() isCurrent}) async {
    bind(op);
    if (!isCurrent() ||
        op.runId == null ||
        (guidance == null
            ? !canStop
            : !canSteer ||
                guidance.trim().isEmpty ||
                op.snapshot.state != RunState.running)) {
      throw StateError('Control unavailable');
    }
    final (code, data, _) = await _request('POST',
        '/v1/runs/${_id(op.runId!)}/${guidance == null ? 'stop' : 'steer'}',
        body: jsonEncode(
            guidance == null ? <String, dynamic>{} : {'input': guidance}));
    if (!isCurrent() ||
        code != 200 ||
        data['run_id'] != op.runId ||
        (guidance != null && data['accepted'] != true)) {
      throw StateError('Control outcome unconfirmed');
    }
  }

  bool get canApprove =>
      capabilities['features'] is Map &&
      (capabilities['features'] as Map)['run_approval_response'] == true &&
      _endpoint('run_approval', 'POST', '/v1/runs/{run_id}/approval');

  /// Discovery has no clarify flag. Only the verified canonical authority
  /// projection (admission + generation + pending_controls) enables this route.
  bool canClarify(RunSnapshot snapshot) =>
      capabilities['features'] is Map &&
      (capabilities['features'] as Map)['run_status'] == true &&
      _endpoint('run_status', 'GET', '/v1/runs/{run_id}') &&
      snapshot.admissionId != null &&
      snapshot.generation != null &&
      snapshot.data['pending_controls'] is List;

  String redactKnownSecrets(String text) =>
      _key.isEmpty ? text : text.replaceAll(_key, '[redacted]');

  Future<(int, Map<String, dynamic>)> respondControl(RunOperation op,
      {required String requestId,
      required int generation,
      String? choice,
      String? answer,
      required bool Function() isCurrent}) async {
    bind(op);
    if (!isCurrent()) throw StateError('Stale control');
    final approval = choice != null && answer == null;
    final pending = PendingControlsSnapshot.fromJson(
        ControlScope(
            sourceId: op.localId, runId: op.runId!, authorityToken: op),
        op.snapshot.data);
    final matches = pending.controls.where((p) =>
        p.promptId == requestId &&
        p.generation == generation &&
        p.action ==
            (approval ? ControlAction.approval : ControlAction.clarify));
    if (matches.length != 1 ||
        !matches.single.accepts(choice ?? answer ?? '')) {
      throw StateError('Control no longer pending');
    }
    if (requestId.isEmpty ||
        requestId.length > 256 ||
        generation < 0 ||
        (approval
            ? !canApprove || !['once', 'deny'].contains(choice)
            : choice != null ||
                answer == null ||
                answer.trim().isEmpty ||
                answer.length > 4000 ||
                !canClarify(op.snapshot))) {
      throw StateError('Unsupported control');
    }
    final (code, data, _) = await _request('POST',
        '/v1/runs/${_id(op.runId!)}/${approval ? 'approval' : 'clarify'}',
        body: jsonEncode({
          'request_id': requestId,
          'execution_generation': generation,
          if (approval) 'choice': choice else 'answer': answer
        }));
    if (!isCurrent()) throw StateError('Stale control');
    return (code, data);
  }

  /// Reports each validated status read even if the resolution later conflicts.
  /// [onObserved] never represents acknowledgement of the control POST.
  Future<void> resolveUnknown(RunOperation op, RunLedger ledger,
      {required bool acknowledgedSideEffects,
      bool Function()? isCurrent,
      Future<void> Function()? onObserved}) async {
    bind(op);
    Future<void> observe() async {
      await status(op, ledger, isCurrent: isCurrent);
      await onObserved?.call();
    }

    await observe();
    if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    final s = op.snapshot;
    if (!acknowledgedSideEffects ||
        !canResolveUnknown ||
        s.state != RunState.unknown ||
        s.admissionId == null ||
        s.generation == null) {
      throw StateError('Unknown execution requires explicit acknowledgement');
    }
    final (code, _, _) = await _request(
        'POST', '/v1/runs/${_id(op.runId!)}/resolve-unknown',
        body: jsonEncode({
          'admission_id': s.admissionId,
          'execution_generation': s.generation
        }));
    if (isCurrent != null && !isCurrent()) throw StateError('Stale run');
    if (code != 200) {
      if (code == 409) await observe();
      throw StateError('Unknown resolution changed; check status');
    }
    await observe();
  }
}
