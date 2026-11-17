/// Native Hermes canonical gateway client. Not an OpenAI-compatible adapter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'bounded_websocket.dart';

enum GatewayConnectionState { disconnected, connecting, connected, disposed }

class GatewayException implements Exception {
  const GatewayException(this.message, {this.code});
  final String message;
  final int? code;
  @override
  String toString() => 'GatewayException: $message';
}

/// Obtain a fresh, trusted grant for EVERY dial. Tickets may be single-use.
/// Credentials are deliberately never included in toString or error messages.
class GatewayGrant {
  GatewayGrant(
      {required this.url,
      this.expectedProfileId,
      this.expectedInstanceId,
      List<String> protocols = const ['hermes-gateway-v1']})
      : protocols = List.unmodifiable(protocols);
  final Uri url;
  final String? expectedProfileId, expectedInstanceId;
  final List<String> protocols;
}

class GatewaySession {
  GatewaySession(Map<String, dynamic> row)
      : id = (row['session_id'] ?? row['id']) as String,
        title = row['title'] as String? ?? '',
        running = row['running'] == true;
  final String id;
  final String title;
  final bool running;
}

enum GatewayRunState { queued, running, complete, failed, cancelled, unknown }

enum GatewayMessageKind { message, toolActivity, compaction, publicNotice }

class GatewayMessage {
  const GatewayMessage(this.role, this.text,
      {this.rowId, this.submissionId, this.kind = GatewayMessageKind.message});
  final String role;
  final String text;
  final int? rowId;
  final String? submissionId;
  final GatewayMessageKind kind;
  bool get isCompletedAnswer =>
      kind == GatewayMessageKind.message &&
      role == 'assistant' &&
      text.trim().isNotEmpty;
}

class GatewayRequest {
  GatewayRequest(Map row)
      : kind = row['kind'] as String,
        id = row['prompt_id'] as String,
        generation = row['execution_generation'] as int,
        choices = List<String>.unmodifiable(row['choices'] as List),
        question = (row['question'] ??
            row['description'] ??
            row['command'] ??
            'Review this action') as String,
        multiSelect = row['multi_select'] == true;
  final String kind, id, question;
  final int generation;
  final List<String> choices;
  final bool multiSelect;
}

class GatewaySnapshot {
  GatewaySnapshot(Map<String, dynamic> value)
      : sessionId = value['session_id'] as String,
        storedSessionId = value['stored_session_id'] as String,
        running = value['running'] == true,
        authorityEpoch = value['authority_epoch'] as int,
        executionGeneration = value['execution_generation'] as int,
        needsUserAction = (value['prompts'] as List? ?? []).isNotEmpty ||
            (value['open_requests'] as List? ?? []).isNotEmpty,
        requests = List.unmodifiable([
          for (final row in value['prompts'] as List? ?? const [])
            if (row is Map &&
                ['approval', 'clarify'].contains(row['kind']) &&
                row['prompt_id'] is String &&
                row['execution_generation'] is int &&
                row['choices'] is List &&
                (row['choices'] as List).every((c) => c is String))
              GatewayRequest(row)
        ]),
        pendingInputs = List.unmodifiable([
          for (final row in value['pending'] as List? ?? const [])
            if (row is Map) Map<String, dynamic>.unmodifiable(row)
        ]),
        messages = List.unmodifiable([
          for (final row
              in (value['display_messages'] ?? value['messages']) as List)
            if (row is Map &&
                ['user', 'assistant', 'tool'].contains(row['role']) &&
                row['display_kind'] != 'hidden')
              GatewayMessage(
                  row['role'] as String,
                  row['role'] == 'tool'
                      ? 'Tool activity: ${row['name'] is String ? row['name'] : 'tool'}'
                      : _visibleText(row['text'] ?? row['content']),
                  kind: row['row_kind'] == 'compaction'
                      ? GatewayMessageKind.compaction
                      : row['role'] == 'tool'
                          ? GatewayMessageKind.toolActivity
                          : row['display_kind'] != null
                              ? GatewayMessageKind.publicNotice
                              : GatewayMessageKind.message,
                  rowId: row['row_id'] is int ? row['row_id'] as int : null,
                  submissionId: row['display_metadata'] is Map &&
                          row['display_metadata']['submission_id'] is String
                      ? row['display_metadata']['submission_id'] as String
                      : null)
        ]);
  final String sessionId;
  final String storedSessionId;
  final bool running;
  final bool needsUserAction;
  final List<GatewayRequest> requests;
  final List<Map<String, dynamic>> pendingInputs;
  final int authorityEpoch;
  final int executionGeneration;
  final List<GatewayMessage> messages;
}

String _visibleText(dynamic value) {
  if (value is String) return value;
  if (value is List) {
    return value
        .whereType<Map>()
        .where((p) => p['type'] == 'text')
        .map((p) => p['text'])
        .whereType<String>()
        .join('\n');
  }
  return '';
}

class GatewayRun {
  GatewayRun._(Map<String, dynamic> receipt, this.inputId)
      : admissionId = receipt['admission_id'] as String,
        sessionId = (receipt['ref'] as Map)['session_id'] as String,
        profileId = (receipt['ref'] as Map)['profile_id'] as String,
        authorityEpoch = receipt['authority_epoch'] as int,
        _executionGeneration = receipt['execution_generation'] as int?,
        _state = _receiptState(receipt);
  final String admissionId;
  final String sessionId;
  final String profileId;
  final String inputId;
  final int authorityEpoch;
  int? _executionGeneration;
  int? get executionGeneration => _executionGeneration;
  GatewayRunState _state;
  GatewayRunState get state => _state;
}

GatewayRunState _receiptState(Map<String, dynamic> value) =>
    switch (value['status']) {
      'started' => GatewayRunState.running,
      'queued' => GatewayRunState.queued,
      'terminal' => switch (value['outcome']) {
          'completed' => GatewayRunState.complete,
          'failed' => GatewayRunState.failed,
          'cancelled' || 'interrupted' => GatewayRunState.cancelled,
          _ => GatewayRunState.unknown,
        },
      _ => GatewayRunState.unknown,
    };

class GatewayEvent {
  const GatewayEvent(
      {required this.type,
      required this.sessionId,
      required this.owned,
      this.text = '',
      this.state});
  final String type;
  final String sessionId;

  /// True only for this client's acknowledged admission AND owner generation.
  final bool owned;
  final String text;
  final GatewayRunState? state;
}

class HermesGatewayClient {
  HermesGatewayClient(
      {required this.grantProvider,
      this.requestTimeout = const Duration(seconds: 30)});
  final Future<GatewayGrant> Function() grantProvider;
  final Duration requestTimeout;
  GatewayConnectionState _state = GatewayConnectionState.disconnected;
  GatewayConnectionState get state => _state;
  final _states = StreamController<GatewayConnectionState>.broadcast();
  Stream<GatewayConnectionState> get states => _states.stream;
  WebSocket? _socket;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  int _connectionEpoch = 0;
  Completer<void>? _dialCancellation;
  void _setState(GatewayConnectionState state) {
    if (_states.isClosed ||
        (_state == GatewayConnectionState.disposed && state != _state)) {
      return;
    }
    _state = state;
    _states.add(state);
  }

  Future<void> connect() async {
    if (_state == GatewayConnectionState.disposed) {
      throw StateError('Client disposed');
    }
    if (_state != GatewayConnectionState.disconnected) {
      throw StateError('Already connecting or connected');
    }
    _setState(GatewayConnectionState.connecting);
    final attempt = ++_connectionEpoch;
    var invalidGrant = false;
    try {
      final grant = await grantProvider();
      if (attempt != _connectionEpoch ||
          _state == GatewayConnectionState.disposed) {
        throw const GatewayException('Connection cancelled');
      }
      final uri = grant.url;
      final loopback = uri.host == 'localhost' ||
          (InternetAddress.tryParse(uri.host)?.isLoopback ?? false);
      final protocols = grant.protocols;
      final tickets = protocols
          .where((p) => p.startsWith('hermes-gateway-ticket.'))
          .toList();
      invalidGrant = uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          !(uri.scheme == 'wss' || (uri.scheme == 'ws' && loopback)) ||
          protocols.toSet().length != protocols.length ||
          protocols.where((p) => p == 'hermes-gateway-v1').length != 1 ||
          tickets.length > 1 ||
          tickets.any((p) => p == 'hermes-gateway-ticket.') ||
          protocols
              .any((p) => p != 'hermes-gateway-v1' && !tickets.contains(p));
      if (invalidGrant) {
        throw const GatewayException('Invalid or insecure gateway grant');
      }
      final cancellation = Completer<void>();
      _dialCancellation = cancellation;
      late WebSocket socket;
      try {
        socket = await connectBoundedWebSocket(grant.url.toString(),
                protocols: grant.protocols,
                maxMessageBytes: 3 * 1024 * 1024,
                maxMessageFragments: 1024,
                connectTimeout: requestTimeout,
                cancelSignal: cancellation.future)
            .then((opened) {
          if (attempt != _connectionEpoch ||
              _state == GatewayConnectionState.disposed) {
            unawaited(opened.close());
            throw const GatewayException('Connection cancelled');
          }
          return opened;
        });
      } finally {
        if (identical(_dialCancellation, cancellation)) {
          _dialCancellation = null;
        }
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 20);
      socket.listen((data) {
        if (identical(_socket, socket)) _receive(data);
      }, onDone: () {
        if (identical(_socket, socket)) _lost();
      }, onError: (Object _) {
        if (identical(_socket, socket)) _lost();
      });
      final runtime = await _request('runtime.describe', {});
      if (!(runtime['capabilities'] is List &&
          (runtime['capabilities'] as List).contains('durable-admission-v1'))) {
        throw const GatewayException(
            'Canonical Hermes session authority required');
      }
      if (attempt != _connectionEpoch ||
          _state == GatewayConnectionState.disposed) {
        throw const GatewayException('Connection cancelled');
      }
      if ((grant.expectedProfileId != null &&
              runtime['profile_id'] != grant.expectedProfileId) ||
          (grant.expectedInstanceId != null &&
              runtime['instance_id'] != grant.expectedInstanceId)) {
        throw const GatewayException(
            'Gateway authority changed; import a fresh host invite');
      }
      _profileId = runtime['profile_id'] as String;
      _capabilities = Set<String>.from(runtime['capabilities'] as List);
      _setState(GatewayConnectionState.connected);
    } catch (_) {
      if (attempt == _connectionEpoch) {
        final socket = _socket;
        _lost();
        await socket?.close();
      }
      throw GatewayException(invalidGrant
          ? 'Invalid or insecure gateway grant'
          : 'Gateway connection or negotiation failed');
    }
  }

  Future<List<GatewaySession>> listSessions(
      {bool stored = false, int limit = 50}) async {
    if (limit < 1 || limit > 200) throw ArgumentError.value(limit, 'limit');
    _requireConnected();
    final result = await _request(
        'session.list', {'scope': stored ? 'stored' : 'live', 'limit': limit});
    final rows = result['sessions'];
    if (rows is! List || rows.length > limit) {
      throw const GatewayException('Invalid or oversized session window');
    }
    return List.unmodifiable(rows
        .map((row) => GatewaySession(Map<String, dynamic>.from(row as Map))));
  }

  Set<String> _capabilities = {};
  String? _transcriptSession, _transcriptCursor;
  List<Map<String, dynamic>> _transcriptRows = [];
  GatewaySnapshot? _attached;
  GatewaySnapshot? get attached => _attached;
  GatewayRun? _run;
  GatewayRun? get run => _run;
  String? _profileId;
  String? get profileId => _profileId;
  bool _submitting = false;
  String? _replayEpoch;
  int _lastSequence = 0;
  bool _needsResync = false;
  bool get needsResync => _needsResync;

  /// Replays observations only. Never replays submissions or approval responses.
  /// False means the bounded server replay cannot fill the gap: call attach().
  Future<bool> replayEvents() async {
    _requireConnected();
    final snapshot = _attached;
    if (snapshot == null) {
      throw const GatewayException('Attach a session first');
    }
    final result = await _request('session.events.since', {
      'session_id': snapshot.sessionId,
      'last_sequence': _lastSequence,
      'replay_epoch': _replayEpoch,
    });
    if (result['snapshot_required'] == true ||
        result['truncated'] == true ||
        result['replay_epoch'] != _replayEpoch) {
      _gap(snapshot.sessionId);
      return false;
    }
    for (final event in result['events'] as List) {
      _event(Map<String, dynamic>.from(event as Map));
    }
    return !_needsResync;
  }

  void _gap(String sessionId) {
    _needsResync = true;
    final run = _run;
    if (run != null &&
        [GatewayRunState.running, GatewayRunState.queued].contains(run.state)) {
      run._state = GatewayRunState.unknown;
    }
    _events.add(GatewayEvent(
        type: 'session.replay_gap', sessionId: sessionId, owned: false));
  }

  bool _attaching = false;
  Future<GatewaySnapshot> attach(String sessionId) async {
    _requireConnected();
    if (_submitting || _attaching) {
      throw StateError('Session operation in progress');
    }
    if (sessionId.isEmpty) throw ArgumentError.value(sessionId, 'sessionId');
    _attaching = true;
    try {
      final result = await _request('session.resume', {
        'session_id': sessionId,
        'display_projection': true,
        if (_capabilities.contains('session-transcript-v1'))
          'omit_messages': true,
      });
      if (_capabilities.contains('session-transcript-v1')) {
        result['display_messages'] =
            await _readTranscript(result['session_id'] as String);
      }
      final snapshot = GatewaySnapshot(result);
      _attached = snapshot;
      _replayEpoch = result['replay_epoch'] as String;
      _lastSequence = result['last_sequence'] as int;
      _needsResync = false;
      return snapshot;
    } finally {
      _attaching = false;
      _flushEvents();
    }
  }

  /// Oldest-order cursors poll additions and reset atomically on lineage rewrites.
  /// Keep only public display text/identity, never raw tool args or reasoning.
  Future<List<Map<String, dynamic>>> _readTranscript(String sessionId) async {
    var cursor = _transcriptSession == sessionId ? _transcriptCursor : null;
    final rows = _transcriptSession == sessionId
        ? List<Map<String, dynamic>>.of(_transcriptRows)
        : <Map<String, dynamic>>[];
    for (var page = 0; page < 256; page++) {
      final value = await _request('session.transcript', {
        'session_id': sessionId,
        'order': 'oldest',
        'limit': 100,
        'inline_images': false,
        if (cursor != null) 'cursor': cursor,
      });
      if (value['session_id'] != sessionId ||
          value['rows'] is! List ||
          value['reset'] is! bool ||
          value['next_cursor'] is! String) {
        throw const GatewayException('Invalid transcript page');
      }
      if (value['reset'] == true) rows.clear();
      final seen = {
        for (final row in rows) '${row['row_kind']}:${row['row_id']}'
      };
      final incoming = value['rows'] as List;
      for (final row in incoming.whereType<Map>()) {
        final id = row['row_id'];
        final kind = row['row_kind'];
        if (id is! int || !['message', 'compaction'].contains(kind)) continue;
        if (!seen.add('$kind:$id')) continue;
        final role = row['role'];
        final metadata = row['display_metadata'];
        if (row['display_kind'] == 'hidden') continue;
        if (['user', 'assistant'].contains(role) || kind == 'compaction') {
          rows.add({
            'row_kind': kind,
            'row_id': id,
            'role': kind == 'compaction' ? 'assistant' : role,
            if (row['display_kind'] is String)
              'display_kind': row['display_kind'],
            'text': kind == 'compaction'
                ? 'Conversation summary: ${_visibleText(row['text'])}'
                : _visibleText(row['text'] ?? row['content']),
            if (metadata is Map && metadata['submission_id'] is String)
              'display_metadata': {'submission_id': metadata['submission_id']},
          });
        } else if (role == 'tool' && row['name'] is String) {
          rows.add({
            'row_kind': kind,
            'row_id': id,
            'role': 'tool',
            'name': row['name'],
            'text': 'Tool activity: ${row['name']}'
          });
        }
      }
      final next = value['next_cursor'] as String;
      if (incoming.isEmpty) {
        _transcriptSession = sessionId;
        _transcriptCursor = next;
        _transcriptRows = rows;
        return rows;
      }
      if (next == cursor) {
        throw const GatewayException('Transcript cursor did not advance');
      }
      cursor = next;
    }
    throw const GatewayException(
        'History is still changing. Resync again; no input was sent.');
  }

  void _flushEvents() {
    final buffered = List<Map<String, dynamic>>.of(_bufferedEvents);
    _bufferedEvents.clear();
    for (final event in buffered) {
      _event(event);
    }
  }

  /// Never sends a transcript, creates a session, or retries an uncertain input.
  /// Retain inputId yourself if you need a durable local submission journal.
  Future<GatewayRun> submit(String text,
      {required String inputId,
      String? expectedSessionId,
      String? expectedProfileId}) async {
    _requireConnected();
    final snapshot = _attached;
    if ((expectedSessionId != null &&
            snapshot?.sessionId != expectedSessionId) ||
        (expectedProfileId != null && _profileId != expectedProfileId)) {
      throw const GatewayException('Original submission authority changed');
    }
    if (snapshot == null) {
      throw const GatewayException('Explicitly attach a session first');
    }
    if (_needsResync) {
      throw const GatewayException(
          'Reload the session snapshot before sending');
    }
    if (text.trim().isEmpty || inputId.isEmpty) {
      throw ArgumentError('Text and inputId required');
    }
    if (_submitting) throw StateError('Submission in progress');
    _submitting = true;
    try {
      final receipt = await _request('prompt.submit', {
        'session_id': snapshot.sessionId,
        'text': text,
        'input_id': inputId,
      });
      if (receipt['ref'] is! Map ||
          receipt['ref']['session_id'] != snapshot.sessionId ||
          receipt['ref']['profile_id'] != _profileId) {
        throw const GatewayException(
            'Unmatched admission receipt; outcome is unknown');
      }
      return _run = GatewayRun._(receipt, inputId);
    } finally {
      _submitting = false;
      _flushEvents();
    }
  }

  /// Generation-fenced control of the acknowledged running execution only.
  /// No new prompt, fallback inference, automatic retry or approval is sent.
  Future<bool> control(String action,
      {required int generation, String? text}) async {
    _requireConnected();
    final run = _run;
    if (!['steer', 'redirect', 'interrupt'].contains(action) ||
        _needsResync ||
        _attached?.needsUserAction == true ||
        run == null ||
        run.sessionId != _attached?.sessionId ||
        run.profileId != _profileId ||
        run.state != GatewayRunState.running ||
        run.executionGeneration != generation) {
      throw const GatewayException(
          'Control authority or execution generation changed');
    }
    if (action != 'interrupt' && (text == null || text.trim().isEmpty)) {
      throw ArgumentError('Control text required');
    }
    final response = await _request('session.$action', {
      'session_id': run.sessionId,
      'execution_generation': generation,
      if (action != 'interrupt') 'text': text
    });
    return response['authority_epoch'] == run.authorityEpoch &&
        response['execution_generation'] == generation &&
        (action == 'interrupt' ||
            ['queued', 'redirected'].contains(response['status']));
  }

  /// Respond only to the exact prompt advertised on this attachment. The server
  /// independently authorizes the actor and rejects stale generation/prompt IDs.
  Future<bool> decide(GatewayRequest prompt, String answer) async {
    _requireConnected();
    final snapshot = _attached;
    if (snapshot == null ||
        !snapshot.requests.contains(prompt) ||
        prompt.generation != snapshot.executionGeneration ||
        (prompt.kind == 'approval' && !prompt.choices.contains(answer)) ||
        answer.trim().isEmpty) {
      return false;
    }
    final result = await _request('${prompt.kind}.respond', {
      'session_id': snapshot.sessionId,
      'execution_generation': prompt.generation,
      'prompt_id': prompt.id,
      prompt.kind == 'approval' ? 'choice' : 'answer': answer,
    });
    return result['prompt_id'] == prompt.id &&
        ['resolved', 'already_resolved'].contains(result['status']);
  }

  /// Recover a journaled admission using a read only; never resubmit its input.
  Future<GatewayRun> recoverRun(
      {required String admissionId, required String inputId}) async {
    _requireConnected();
    final snapshot = _attached;
    if (snapshot == null) {
      throw const GatewayException('Attach the original session first');
    }
    final receipt = await _request('prompt.receipt', {
      'session_id': snapshot.sessionId,
      'admission_id': admissionId,
    });
    if (receipt['admission_id'] != admissionId ||
        receipt['ref'] is! Map ||
        receipt['ref']['session_id'] != snapshot.sessionId ||
        receipt['ref']['profile_id'] != _profileId) {
      throw const GatewayException('Unmatched admission receipt');
    }
    return _run = GatewayRun._(receipt, inputId);
  }

  /// Reconcile an acknowledged admission after reconnect, without sending input.
  Future<GatewayRun> refreshRun() async {
    _requireConnected();
    final run = _run;
    if (run == null ||
        run.profileId != _profileId ||
        run.sessionId != _attached?.sessionId) {
      throw const GatewayException(
          'Attach the original run owner before checking its receipt');
    }
    final receipt = await _request('prompt.receipt', {
      'session_id': run.sessionId,
      'admission_id': run.admissionId,
    });
    if (receipt['admission_id'] != run.admissionId ||
        receipt['ref'] is! Map ||
        receipt['ref']['session_id'] != run.sessionId ||
        receipt['ref']['profile_id'] != run.profileId) {
      throw const GatewayException('Unmatched admission receipt');
    }
    return _run = GatewayRun._(receipt, run.inputId);
  }

  void _requireConnected() {
    if (_state != GatewayConnectionState.connected) {
      throw const GatewayException('Gateway is disconnected');
    }
  }

  Future<Map<String, dynamic>> _request(
      String method, Map<String, dynamic> params) async {
    final socket = _socket;
    if (socket == null) throw const GatewayException('Gateway is disconnected');
    final id = 'saathi-${++_nextId}';
    final reply = Completer<Map<String, dynamic>>();
    _pending[id] = reply;
    try {
      socket.add(jsonEncode(
          {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
      return await reply.future.timeout(requestTimeout,
          onTimeout: () => throw const GatewayException(
              'Request timed out; outcome may be unknown'));
    } finally {
      _pending.remove(id);
    }
  }

  final _events = StreamController<GatewayEvent>.broadcast();
  Stream<GatewayEvent> get events => _events.stream;

  final _bufferedEvents = <Map<String, dynamic>>[];
  void _event(Map<String, dynamic> event) {
    if (_submitting || _attaching) {
      if (_bufferedEvents.length >= 256) {
        _socket?.close();
        _lost();
        return;
      }
      _bufferedEvents.add(event);
      return;
    }
    final type = event['type'];
    final sessionId = event['session_id'];
    if (sessionId is! String || sessionId != _attached?.sessionId) return;
    if (type == 'session.replay_gap') {
      _gap(sessionId);
      return;
    }
    if (_needsResync) return;
    if (event['replay_epoch'] != _replayEpoch) {
      _gap(sessionId);
      return;
    }
    final sequence = event['seq'];
    if (sequence is! int || sequence <= _lastSequence) return;
    _lastSequence = sequence;
    if (![
      'message.delta',
      'message.complete',
      'approval.request',
      'clarify.request',
      'session.replay_gap'
    ].contains(type)) {
      return;
    }
    final payload =
        event['payload'] is Map ? event['payload'] as Map : const {};
    final run = _run;
    final sameAdmission = run != null &&
        event['admission_id'] == run.admissionId &&
        sessionId == run.sessionId &&
        _profileId == run.profileId &&
        event['authority_epoch'] == run.authorityEpoch;
    if (sameAdmission &&
        run.executionGeneration == null &&
        event['execution_generation'] is int) {
      run._executionGeneration = event['execution_generation'] as int;
    }
    final owned = sameAdmission &&
        event['execution_generation'] == run.executionGeneration;
    GatewayRunState? state;
    if (owned &&
        type == 'message.delta' &&
        run.state == GatewayRunState.queued) {
      run._state = GatewayRunState.running;
    }
    if (type == 'message.complete') {
      state = payload['error'] != null ||
              payload['failure_reason'] != null ||
              payload['partial'] == true
          ? GatewayRunState.failed
          : switch (payload['status']) {
              'complete' => GatewayRunState.complete,
              'error' => GatewayRunState.failed,
              'interrupted' => GatewayRunState.cancelled,
              _ => GatewayRunState.unknown,
            };
      if (owned) run._state = state;
    }
    // Whitelist fields. No raw payload, hidden reasoning, tool arguments or errors.
    _events.add(GatewayEvent(
        type: type as String,
        sessionId: sessionId,
        owned: owned,
        state: state,
        text: ['message.delta', 'message.complete'].contains(type)
            ? _visibleText(payload['text'])
            : ''));
  }

  void _receive(dynamic data) {
    try {
      // Official transcript pages can contain 2 MiB of JSON plus RPC envelope.
      final limit = (_capabilities.contains('session-transcript-v1') ? 3 : 1) *
          1024 *
          1024;
      if (data is! String ||
          data.length > limit ||
          utf8.encode(data).length > limit) {
        unawaited(_socket?.close(WebSocketStatus.messageTooBig));
        _lost();
        return;
      }
      final frames = data.split('\n').where((line) => line.trim().isNotEmpty);
      for (final frame in frames) {
        final value = jsonDecode(frame) as Map<String, dynamic>;
        if (value['method'] == 'event' && value['params'] is Map) {
          _event(Map<String, dynamic>.from(value['params'] as Map));
          continue;
        }
        final pending = _pending[value['id']];
        if (pending == null) continue;
        if (value['error'] is Map) {
          final error = value['error'] as Map;
          pending.completeError(GatewayException('Gateway rejected request',
              code: error['code'] as int?));
        } else if (value['result'] is Map) {
          pending.complete(Map<String, dynamic>.from(value['result'] as Map));
        } else {
          pending.completeError(
              const GatewayException('Invalid gateway response'));
        }
      }
    } catch (_) {
      _socket?.close(WebSocketStatus.protocolError);
      _lost();
    }
  }

  void _lost() {
    ++_connectionEpoch;
    final cancellation = _dialCancellation;
    _dialCancellation = null;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _socket = null;
    _attached = null;
    final run = _run;
    if (run != null &&
        [GatewayRunState.running, GatewayRunState.queued].contains(run.state)) {
      run._state = GatewayRunState.unknown;
    }
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(const GatewayException(
            'Connection lost; request outcome may be unknown'));
      }
    }
    _pending.clear();
    if (_state != GatewayConnectionState.disposed &&
        _state != GatewayConnectionState.disconnected) {
      _setState(GatewayConnectionState.disconnected);
    }
  }

  Future<void> disconnect() async {
    final socket = _socket;
    _lost();
    await socket?.close();
  }

  Future<void> dispose() async {
    if (_state == GatewayConnectionState.disposed) return;
    final socket = _socket;
    _lost();
    _setState(GatewayConnectionState.disposed);
    await socket?.close();
    await _states.close();
    await _events.close();
  }
}
