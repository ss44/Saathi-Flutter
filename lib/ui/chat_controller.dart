import 'dart:async';
import '../agent_runs/run_client.dart';
import '../agent_controls/agent_controls.dart';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../core/saathi_core.dart';
import '../notifications/reply_notifications.dart';
import '../storage/saathi_store.dart';

class ChatSession {
  final String id, connectionId, model, systemPrompt;
  final List<ChatMessage> messages;
  ChatSession(
      {required this.id,
      required this.connectionId,
      required this.model,
      this.systemPrompt = '',
      List<ChatMessage>? messages})
      : messages = messages ?? [];
  String get title =>
      messages.isEmpty ? 'New conversation' : messages.first.content;
  Map<String, dynamic> toJson() => {
        'id': id,
        'connectionId': connectionId,
        'model': model,
        'systemPrompt': systemPrompt,
        'messages': messages.map((m) => m.toJson()).toList()
      };
  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
      id: json['id'],
      connectionId: json['connectionId'],
      model: json['model'],
      systemPrompt: json['systemPrompt'] ?? '',
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
          .toList());
}

typedef CoreFactory = SaathiCore Function();

enum _DispatchResult { completed, admitted, dispatchedUnknown, notDispatched }

class _DispatchPermission {
  final QueuedFollowup source;
  bool revoked = false;
  _DispatchPermission(this.source);
}

class QueuedFollowup {
  final String text;
  final ChatSession session;
  final Map<String, dynamic> connection;
  QueuedFollowup(this.text, this.session, this.connection);
}

/// Local identity plus original server authority; never use a bare run ID as
/// cross-server identity. The opaque revision is not a connection/key map.
class ScopedRunSnapshot {
  ScopedRunSnapshot(
      {required this.localChatId,
      required this.connectionId,
      required this.connectionRevision,
      required this.operationKey,
      required Map<String, String?> originalAuthority,
      required this.snapshot,
      required bool Function() isCurrent,
      bool Function()? isObservable,
      this.eventsSupported = false,
      this.originalConnection})
      : originalAuthority = Map.unmodifiable(originalAuthority),
        _isCurrent = isCurrent,
        _isObservable = isObservable ?? isCurrent;
  final bool eventsSupported;
  final Map<String, dynamic>? originalConnection;
  final String localChatId, connectionId, operationKey;
  final Object connectionRevision;
  final Map<String, String?> originalAuthority;
  final RunSnapshot snapshot;
  final bool Function() _isCurrent;
  final bool Function() _isObservable;
  bool isCurrent() => _isCurrent();
  bool isObservable() => _isObservable();
}

class ChatController extends ChangeNotifier {
  final List<QueuedFollowup> _outbox = [];
  List<QueuedFollowup> get outbox => List.unmodifiable(
      _outbox.where((item) => identical(item.session, current)));
  final Map<ChatSession, QueuedFollowup> _uncertain = {};
  final Map<ChatSession, String> _paused = {};
  QueuedFollowup? get uncertainInput => _uncertain[current];
  String? get queueStatus =>
      uncertainInput != null || outbox.isNotEmpty ? _paused[current] : null;
  bool _draining = false, _background = false;
  _DispatchPermission? _preparing;

  bool _bound(QueuedFollowup item) =>
      identical(current, item.session) &&
      sessions.contains(item.session) &&
      connections.any((c) => identical(c, item.connection)) &&
      item.connection['id'] == item.session.connectionId;

  bool submit(String text) {
    final session = current;
    if (_disposed ||
        loading ||
        readOnly ||
        changingConnection ||
        unsavedChanges ||
        queueStatus != null ||
        uncertainInput != null ||
        _background ||
        session == null ||
        text.trim().isEmpty) {
      return false;
    }
    final connection =
        connections.singleWhere((c) => c['id'] == session.connectionId);
    _outbox.add(QueuedFollowup(text, session, connection));
    unawaited(_drainOutbox());
    notifyListeners();
    return true;
  }

  void cancelQueued(QueuedFollowup item) {
    _outbox.remove(item);
    if (!_outbox.any((i) => identical(i.session, item.session)) &&
        !_uncertain.containsKey(item.session)) {
      _paused.remove(item.session);
    }
    notifyListeners();
  }

  // Call only after acknowledgment of the unknown server outcome.
  void abandonHeldOutbox(ChatSession session) {
    if (_disposed || !_uncertain.containsKey(session)) return;
    _outbox.removeWhere((item) => identical(item.session, session));
    _uncertain.remove(session);
    _paused.remove(session);
    notifyListeners();
  }

  void pauseQueue(String reason,
      {ChatSession? session, bool allSources = false}) {
    final source = session ?? current;
    final preparing = _preparing;
    if (preparing != null &&
        (allSources || identical(preparing.source.session, source))) {
      preparing.revoked = true;
      _paused[preparing.source.session] = reason;
    }
    for (final item in _outbox) {
      if (allSources || identical(item.session, source)) {
        _paused[item.session] = reason;
      }
    }
    notifyListeners();
  }

  void setQueueBackground(bool background) {
    _background = background;
    if (background) {
      pauseQueue(
          'Queue paused while Saathi is in the background. Return and choose Resume.',
          allSources: true);
    }
  }

  bool get canResumeQueue =>
      !_disposed &&
      !_background &&
      !busy &&
      !runPending &&
      !loading &&
      !readOnly &&
      !changingConnection &&
      !unsavedChanges &&
      uncertainInput == null &&
      outbox.isNotEmpty &&
      outbox.every(_bound);

  void resumeQueue() {
    if (!canResumeQueue) return;
    _paused.remove(current);
    unawaited(_drainOutbox());
  }

  void _scheduleSelectedQueue() {
    if (!_draining &&
        !busy &&
        !runPending &&
        !_disposed &&
        !_background &&
        !loading &&
        !readOnly &&
        !changingConnection &&
        !unsavedChanges &&
        queueStatus == null &&
        uncertainInput == null &&
        outbox.isNotEmpty &&
        outbox.every(_bound)) {
      scheduleMicrotask(_drainOutbox);
    }
  }

  Future<void> _drainOutbox() async {
    if (_draining || busy || runPending || _disposed) return;
    _draining = true;
    try {
      while (outbox.isNotEmpty && !_disposed) {
        if (busy || runPending) break;
        if (queueStatus != null || uncertainInput != null) break;
        if (_background ||
            loading ||
            readOnly ||
            changingConnection ||
            unsavedChanges ||
            !_bound(outbox.first)) {
          pauseQueue(
              'Queue paused. Restore the original conversation and connection, and save before resuming.');
          break;
        }
        final item = outbox.first;
        _outbox.remove(item);
        final result = await _dispatch(item.text, source: item);
        if (result == _DispatchResult.notDispatched) {
          _outbox.insert(0, item);
          _paused.putIfAbsent(item.session,
              () => 'Not sent. Queue held. Choose Resume when ready.');
          break;
        }
        if (result == _DispatchResult.dispatchedUnknown) {
          _uncertain[item.session] = item;
          _paused[item.session] =
              'Outcome unknown. The last request may have executed. It will not be sent again. Start a new conversation safely, or explicitly abandon this held outbox.';
          break;
        }
        if (result == _DispatchResult.admitted) break;
        if (unsavedChanges) {
          pauseQueue(
              'Queue paused until the response is saved. Then choose Resume.',
              allSources: true);
          break;
        }
      }
    } finally {
      _draining = false;
      _paused.removeWhere((session, _) =>
          !_uncertain.containsKey(session) &&
          !_outbox.any((item) => identical(item.session, session)));
      _scheduleSelectedQueue();
      notifyListeners();
    }
  }

  final SaathiStore store;
  final CoreFactory coreFactory;
  void Function(String sessionId)? onReplyReceived;
  ReplyNotifications? notifications;
  final List<Map<String, dynamic>> connections = [];
  final List<ChatSession> sessions = [];
  ChatSession? current;
  bool loading = true, busy = false, unsavedChanges = false;
  bool _disposed = false;
  bool _loadFailed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    _runUpdates.close();
    _scopedRunUpdates.close();
    onReplyReceived = null;
    super.dispose();
  }

  String? error, _pendingText;
  String? get pendingText {
    final op = currentRun;
    if (op != null &&
        !current!.messages.any((m) => m.id == 'input-${op.key}')) {
      return op.input;
    }
    return _pendingText;
  }

  set pendingText(String? value) => _pendingText = value;
  final RunClientFactory? runClientFactory;
  final bool _runDiscovery;
  final Map<String, RunOperation> runs = {};
  final _runUpdates = StreamController<RunSnapshot>.broadcast();

  /// Compatibility stream; new integrations should use scopedRunSnapshots.
  Stream<RunSnapshot> get runSnapshots => _runUpdates.stream;
  final _scopedRunUpdates = StreamController<ScopedRunSnapshot>.broadcast();
  final _connectionRevisions = Expando<Object>();
  final _activityEvents = Expando<bool>();
  Stream<ScopedRunSnapshot> get scopedRunSnapshots => _scopedRunUpdates.stream;
  RunOperation? get currentRun => runs[current?.id];
  bool get runPending =>
      currentRun != null &&
      (!currentRun!.committed || currentRun!.data['journalDirty'] == true);
  bool _runsPaused = false;
  int _runsGeneration = 0;
  Timer? _poll;
  ChatController(this.store, {CoreFactory? coreFactory, this.runClientFactory})
      : _runDiscovery = coreFactory == null || runClientFactory != null,
        coreFactory = coreFactory ?? (() => SaathiCore());

  RunLedger get _ledger => RunLedger(store.secrets);
  Future<AgentControlsController?> openRunControls(
      {required bool Function() isOwnerCurrent}) async {
    final session = current;
    final op = currentRun;
    if (session == null || op?.runId == null) return null;
    final connection =
        connections.where((c) => c['id'] == session.connectionId).firstOrNull;
    if (connection == null) return null;
    final operation = op!;
    final key = operation.key;
    final runId = operation.runId!;
    final epoch = connection['authorityEpoch'];
    final origin = connection['url'];
    bool valid() =>
        isOwnerCurrent() &&
        identical(current, session) &&
        _active(session, connection, operation) &&
        operation.key == key &&
        operation.runId == runId &&
        connection['authorityEpoch'] == epoch &&
        connection['url'] == origin &&
        operation.data['authorityEpoch'] == epoch;
    if (!valid()) return null;
    final client = await _runClient(connection, isCurrent: valid);
    try {
      client.bind(operation);
      if (!await client.discover() || !valid()) {
        client.close();
        return null;
      }
      final revision = _connectionRevisions[connection] ??= Object();
      final scope = ControlScope(
          sourceId: session.id, runId: runId, authorityToken: revision);
      final controller = AgentControlsController(
          ControlBoundary(
              scope: scope,
              isCurrentAuthority: (s) => valid() && s.matches(scope),
              supportsAction: (action) =>
                  valid() &&
                  (action == ControlAction.approval
                      ? client.canApprove
                      : client.canClarify(operation.snapshot)),
              refresh: () async {
                final snapshot =
                    await client.status(operation, _ledger, isCurrent: valid);
                if (!valid()) throw StateError('Stale controls');
                await _reconcile(session, connection, operation);
                if (!valid()) throw StateError('Stale controls');
                // A control's fresh GET can observe terminal completion before
                // the normal poll. Wake only through the existing durable,
                // source-bound queue gate; explicit pauses remain intact.
                _scheduleSelectedQueue();
                return PendingControlsSnapshot.fromJson(scope, snapshot.data);
              },
              postDecision: (action, body) async {
                if (!valid()) throw StateError('Stale controls');
                final (code, data) = await client.respondControl(operation,
                    requestId: body['request_id'] as String,
                    generation: body['execution_generation'] as int,
                    choice: action == ControlAction.approval
                        ? body['choice'] as String
                        : null,
                    answer: action == ControlAction.clarify
                        ? body['answer'] as String
                        : null,
                    isCurrent: valid);
                return ControlPostResult(code, data);
              }),
          redact: client.redactKnownSecrets,
          onDispose: client.close);
      await controller.refresh();
      if (!valid()) {
        controller.dispose();
        return null;
      }
      return controller;
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  void pauseRuns(bool paused) {
    if (paused) _runsGeneration++;
    _runsPaused = paused;
    _poll?.cancel();
    if (!paused && !_disposed) _schedulePoll();
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (_runsPaused ||
        _disposed ||
        !runs.values.any((r) =>
            !r.committed &&
            r.runId != null &&
            !r.snapshot.terminal &&
            r.snapshot.state != RunState.unknown)) {
      return;
    }
    _poll = Timer(const Duration(seconds: 2), () async {
      for (final session in sessions.toList()) {
        if (_runsPaused || _disposed) break;
        final op = runs[session.id];
        if (op != null &&
            !op.committed &&
            op.runId != null &&
            !op.snapshot.terminal) {
          await checkRunStatus(sessionId: session.id);
        }
      }
      _schedulePoll();
    });
  }

  Future<RunClient> _runClient(Map<String, dynamic> connection,
      {required bool Function() isCurrent}) async {
    final key = await store.secrets.read(connection['id'] as String) ?? '';
    if (!isCurrent()) {
      throw StateError('Connection changed');
    }
    return (runClientFactory ?? ((root, key) => RunClient(root, key)))(
        connection['url'] as String? ?? 'http://127.0.0.1:8642', key);
  }

  bool _active(ChatSession session, Map<String, dynamic> connection,
          [RunOperation? op]) =>
      !_disposed &&
      !_runsPaused &&
      !_loadFailed &&
      sessions.contains(session) &&
      connections.any((c) => identical(c, connection)) &&
      (op == null || identical(runs[session.id], op));

  Future<void> _commitRun(ChatSession session, Map<String, dynamic> connection,
      RunOperation op) async {
    final generation = _runsGeneration;
    bool isCurrent() =>
        generation == _runsGeneration && _active(session, connection, op);
    if (!isCurrent()) return;
    // Do not expose committed=true until both history and journal are durable.
    final durable =
        RunOperation({...op.data, 'committed': true, 'journalDirty': false});
    await _ledger.save(durable, isCurrent: isCurrent);
    if (!isCurrent()) return;
    op.data['committed'] = true;
    op.data['journalDirty'] = false;
  }

  Future<void> _reconcile(ChatSession session, Map<String, dynamic> connection,
      RunOperation op) async {
    final generation = _runsGeneration;
    bool isCurrent() =>
        generation == _runsGeneration && _active(session, connection, op);
    if (!isCurrent()) return;
    final snapshot = op.snapshot;
    if (!_runUpdates.isClosed) _runUpdates.add(snapshot);
    if (!_scopedRunUpdates.isClosed) {
      final revision = _connectionRevisions[connection] ??= Object();
      final epoch = op.data['authorityEpoch'];
      final root = connection['url'];
      _scopedRunUpdates.add(ScopedRunSnapshot(
          localChatId: session.id,
          connectionId: session.connectionId,
          connectionRevision: revision,
          operationKey: op.key,
          originalAuthority: {
            'origin': op.data['origin'] as String?,
            'authorityEpoch': op.data['authorityEpoch'] as String?,
            'credentialScope': op.data['scope'] as String?,
          },
          snapshot: snapshot,
          originalConnection: connection,
          eventsSupported: _activityEvents[connection] == true,
          // Read-only telemetry survives operation replacement, never controls.
          isCurrent: isCurrent,
          isObservable: () =>
              _active(session, connection) &&
              epoch == connection['authorityEpoch'] &&
              root == connection['url']));
    }
    if (snapshot.terminal && !op.committed) op.data['journalDirty'] = true;
    if (snapshot.state == RunState.completed) {
      final marker = 'run-${op.key}';
      if (!session.messages.any((m) => m.id == marker)) {
        session.messages.addAll([
          ChatMessage(role: 'user', content: op.input, id: 'input-${op.key}'),
          ChatMessage(role: 'model', content: snapshot.output, id: marker)
        ]);
        if (op.data['alertClaimed'] != true) {
          op.data['alertClaimed'] = true;
          try {
            await _ledger.save(op, isCurrent: isCurrent);
            if (!isCurrent()) return;
            onReplyReceived?.call(session.id);
          } catch (_) {
            if (!isCurrent()) return;
          }
        }
      }
      if (!isCurrent()) return;
      try {
        await store.saveChats(sessions.map((s) => s.toJson()).toList());
        if (!isCurrent()) return;
        await _commitRun(session, connection, op);
        if (!isCurrent()) return;
        unsavedChanges = false;
      } catch (_) {
        if (!isCurrent()) return;
        unsavedChanges = true;
        pauseQueue(
            'Queue paused until the response is saved. Then choose Resume.',
            allSources: true);
        error =
            'Response received but not saved. Try saving again; do not resend.';
      }
    } else if (snapshot.terminal) {
      _paused[session] =
          'Run ${snapshot.status}. Prior work may have had side effects. Review before choosing Resume.';
      try {
        await _commitRun(session, connection, op);
        if (!isCurrent()) return;
        error = 'Run ${snapshot.status}. Prior work may have had side effects.';
      } catch (_) {
        if (!isCurrent()) return;
        unsavedChanges = true;
        error = 'Run result not saved. Try saving again; do not resend.';
      }
    }
    if (snapshot.state == RunState.unknown ||
        snapshot.state == RunState.unrecognized) {
      _paused[session] =
          'Run outcome unknown. Check the original run; never resend it with a fresh key.';
    }
    if (isCurrent()) notifyListeners();
  }

  Future<void> checkRunStatus(
      {String? sessionId, bool acknowledgeUnknown = false}) async {
    if (_disposed || _runsPaused || busy) return;
    final session =
        sessions.where((s) => s.id == (sessionId ?? current?.id)).firstOrNull;
    if (session == null) return;
    final op = runs[session.id];
    if (op == null) return;
    final generation = _runsGeneration;
    RunClient? client;
    busy = true;
    notifyListeners();
    try {
      final c = connections.singleWhere((c) => c['id'] == session.connectionId);
      bool isCurrent() =>
          generation == _runsGeneration && _active(session, c, op);
      client = await _runClient(c, isCurrent: isCurrent);
      if (!isCurrent()) return;
      if (op.data['authorityEpoch'] != c['authorityEpoch']) {
        throw StateError('Original connection creation required');
      }
      client.bind(op);
      if (op.snapshot.terminal) {
        await _reconcile(session, c, op);
        return;
      }
      if (!await client.discover()) throw StateError('Runs unavailable');
      if (!isCurrent()) return;
      _activityEvents[c] = client.eventsSupported;
      if (op.runId == null) {
        // Explicit reconnect only: identical key/body, within the replay window.
        await client.submit(op, _ledger, isCurrent: isCurrent);
      }
      if (op.runId != null) {
        if (acknowledgeUnknown) {
          await client.resolveUnknown(op, _ledger,
              acknowledgedSideEffects: true, isCurrent: isCurrent);
        } else {
          await client.status(op, _ledger, isCurrent: isCurrent);
        }
        if (!isCurrent()) return;
        await _reconcile(session, c, op);
      }
      error ??= op.runId == null
          ? 'Admission saved; outcome unknown. Reconnect without sending again.'
          : null;
    } catch (_) {
      error =
          'Could not confirm this run. Keep its original connection and use Reconnect. Do not resend.';
    } finally {
      client?.close();
      busy = false;
      _scheduleSelectedQueue();
      notifyListeners();
    }
  }

  Future<_DispatchResult?> _sendRun(
      ChatSession session,
      Map<String, dynamic> connection,
      String text,
      _DispatchPermission permission) async {
    if (connection['type'] != 'hermes' || !_runDiscovery) return null;
    final previous = runs[session.id];
    final generation = _runsGeneration;
    bool isCurrent() =>
        generation == _runsGeneration &&
        _active(session, connection) &&
        !permission.revoked &&
        _bound(permission.source) &&
        !_background &&
        identical(runs[session.id], previous);
    final client = await _runClient(connection, isCurrent: isCurrent);
    try {
      if (!isCurrent()) throw StateError('Stale run');
      final supported = await client.discover();
      _activityEvents[connection] = client.eventsSupported;
      if (!isCurrent()) throw StateError('Stale run');
      if (!supported) {
        if (previous != null) {
          throw StateError('Existing run requires its original Runs authority');
        }
        return null;
      }
      if (previous != null &&
          previous.data['authorityEpoch'] != connection['authorityEpoch']) {
        throw StateError('Original connection creation required');
      }
      final op = await client.prepare(_ledger,
          authorityEpoch: connection['authorityEpoch'] as String?,
          isCurrent: isCurrent,
          local: session.id,
          input: text,
          model: session.model,
          instructions: session.systemPrompt,
          history: session.messages
              .map((m) => {
                    'role': m.role == 'model' ? 'assistant' : m.role,
                    'content': m.content
                  })
              .toList(),
          previous: previous);
      if (!isCurrent()) throw StateError('Stale run');
      runs[session.id] = op;
      await client.submit(op, _ledger,
          isCurrent: () =>
              generation == _runsGeneration &&
              _active(session, connection, op) &&
              !permission.revoked &&
              _bound(permission.source) &&
              !_background);
      if (op.runId != null && !_disposed && !_runsPaused) {
        await client.status(op, _ledger,
            isCurrent: () =>
                generation == _runsGeneration &&
                _active(session, connection, op));
        if (generation != _runsGeneration ||
            !_active(session, connection, op)) {
          return _DispatchResult.admitted;
        }
        await _reconcile(session, connection, op);
      }
      _schedulePoll();
      return op.committed && op.snapshot.state == RunState.completed
          ? _DispatchResult.completed
          : _DispatchResult.admitted;
    } on PreparedRunRevoked catch (e) {
      // Retain only in the captured original chat; the journal owns this input,
      // so the queue must not restore another copy or allocate another key.
      runs[session.id] = e.operation;
      _paused[session] =
          'Not sent. Prepared operation held. Reconnect using the original operation.';
      error = _paused[session];
      return _DispatchResult.admitted;
    } finally {
      client.close();
    }
  }

  Future<void> load() async {
    try {
      final data = await store.load();
      connections.addAll(data.connections);
      sessions.addAll(data.chats.map(ChatSession.fromJson));
      for (final session in sessions) {
        final op = await _ledger.load(session.id);
        if (op != null) runs[session.id] = op;
      }
      if (sessions.isNotEmpty) current = sessions.last;
    } catch (_) {
      _loadFailed = true;
      error =
          'Saved data could not be read. Nothing has been overwritten. Restart after restoring your local data.';
    }
    loading = false;
    notifyListeners();
  }

  ProviderConfig config(Map<String, dynamic> c, String key) => ProviderConfig(
      id: c['id'],
      name: c['name'],
      type: ProviderType.values.byName(c['type']),
      apiKey: key,
      baseUrl: c['url']);
  bool isCurrentConnection(Map<String, dynamic> connection) =>
      !_disposed && connections.any((c) => identical(c, connection));

  Future<SaathiCore> coreFor(Map<String, dynamic> c) async {
    final core = coreFactory();
    try {
      core.addProvider(config(c, await store.secrets.read(c['id']) ?? ''));
      return core;
    } catch (_) {
      core.close();
      rethrow;
    }
  }

  Future<void> addConnection(Map<String, dynamic> c, String key) async {
    if (!canChangeConnections) {
      throw StateError('Connection unavailable or work in progress');
    }
    changingConnection = true;
    notifyListeners();
    try {
      final created = {
        ...c,
        if (c['type'] == 'hermes') 'authorityEpoch': runIdentity()
      };
      await store.saveConnection(created, apiKey: key);
      if (!_disposed) connections.add(created);
    } on StorageRecoveryException {
      _failClosed();
      rethrow;
    } finally {
      changingConnection = false;
      notifyListeners();
    }
  }

  bool changingConnection = false;
  bool get canChangeConnections =>
      !_disposed && !loading && !busy && !changingConnection && !_loadFailed;
  void _failClosed() {
    _loadFailed = true;
    error =
        'Secure storage recovery could not be confirmed. Connections are read-only; restart after checking storage.';
  }

  bool get readOnly =>
      _loadFailed ||
      current != null &&
          !connections.any((c) => c['id'] == current!.connectionId);

  void _checkMutation(String id) {
    if (_disposed ||
        loading ||
        busy ||
        changingConnection ||
        _loadFailed ||
        !connections.any((c) => c['id'] == id)) {
      throw StateError('Connection unavailable or work in progress');
    }
  }

  Future<void> updateConnection(String id, Map<String, dynamic> values,
      {String? apiKey}) async {
    _checkMutation(id);
    final old = connections.singleWhere((c) => c['id'] == id);
    final revised =
        old['type'] != values['type'] || old['url'] != values['url'];
    final next = <String, dynamic>{
      ...old,
      ...values,
      if (old['type'] == 'hermes' || values['type'] == 'hermes')
        'authorityEpoch':
            revised || apiKey != null ? runIdentity() : old['authorityEpoch'],
      'id': revised
          ? List.generate(
              24,
              (_) => Random.secure()
                  .nextInt(256)
                  .toRadixString(16)
                  .padLeft(2, '0')).join()
          : id
    };
    changingConnection = true;
    notifyListeners();
    try {
      await store.changeConnection(id, replacement: next, apiKey: apiKey);
      if (_disposed) return;
      connections[connections.indexOf(old)] = next;
    } on StorageRecoveryException {
      _failClosed();
      rethrow;
    } finally {
      changingConnection = false;
      notifyListeners();
    }
  }

  Future<void> deleteConnection(String id) async {
    _checkMutation(id);
    changingConnection = true;
    notifyListeners();
    try {
      await store.changeConnection(id);
      if (_disposed) return;
      connections.removeWhere((c) => c['id'] == id);
    } on StorageRecoveryException {
      _failClosed();
      rethrow;
    } finally {
      changingConnection = false;
      notifyListeners();
    }
  }

  Future<List<ModelInfo>> discover(Map<String, dynamic> c) async {
    final core = await coreFor(c);
    try {
      return await core.discoverModels(c['id']);
    } finally {
      core.close();
    }
  }

  Future<void> newSession(
      Map<String, dynamic> c, String model, String prompt) async {
    _checkMutation(c['id'] as String);
    final session = ChatSession(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        connectionId: c['id'],
        model: model,
        systemPrompt: prompt);
    final previous = current;
    sessions.add(session);
    current = session;
    error = null;
    try {
      await persist();
    } catch (_) {
      sessions.remove(session);
      current = previous;
      rethrow;
    }
    notifyListeners();
  }

  bool openNotificationConversation(String id) {
    if (_disposed || loading || !validConversationId(id)) return false;
    final found = sessions.where((s) => s.id == id);
    if (found.length != 1) return false;
    select(found.single);
    return true;
  }

  void select(ChatSession session) {
    if (!identical(current, session)) {
      pauseQueue(
          'Queue paused because the conversation changed. Return to the original conversation and choose Resume.');
    }
    current = session;
    if (!_loadFailed) error = null;
    notifyListeners();
  }

  Future<void> persist() async {
    if (_loadFailed) {
      throw StateError('Saved data must be recovered before writing');
    }
    await store.saveChats(sessions.map((s) => s.toJson()).toList());
    unsavedChanges = false;
  }

  Future<void> retrySave() async {
    // Runs lifecycle suspension must not disable legacy history-only recovery.
    final nativePaused = _runsPaused && runs.isNotEmpty;
    if (_disposed || nativePaused || _loadFailed || busy) return;
    final captured = <(ChatSession, Map<String, dynamic>, RunOperation)>[];
    for (final session in sessions.toList()) {
      final op = runs[session.id];
      final connection =
          connections.where((c) => c['id'] == session.connectionId).firstOrNull;
      if (op != null &&
          connection != null &&
          op.snapshot.terminal &&
          op.data['authorityEpoch'] == connection['authorityEpoch']) {
        captured.add((session, connection, op));
      }
    }
    busy = true;
    try {
      await store.saveChats(sessions.map((s) => s.toJson()).toList());
      if (_disposed || (_runsPaused && runs.isNotEmpty) || _loadFailed) return;
      for (final (session, connection, op) in captured) {
        if (!_active(session, connection, op)) return;
        if (op.snapshot.state == RunState.completed &&
            !session.messages.any((m) => m.id == 'run-${op.key}')) {
          continue;
        }
        await _commitRun(session, connection, op);
        if (!_active(session, connection, op)) return;
      }
      unsavedChanges = false;
      error = null;
    } catch (_) {
      if (_disposed || (_runsPaused && runs.isNotEmpty) || _loadFailed) return;
      unsavedChanges = true;
      error =
          'Conversation is still not saved. Keep Saathi open and try again.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> clear() async {
    if (busy || current == null) return;
    // A fresh ID also clears any backend-owned state; never re-use a cleared thread.
    final old = current!;
    final index = sessions.indexOf(old);
    sessions.remove(old);
    current = null;
    try {
      await persist();
    } catch (_) {
      sessions.insert(index, old);
      current = old;
      rethrow;
    }
    notifyListeners();
  }

  Future<bool> send(String text) async {
    if (_draining ||
        unsavedChanges ||
        _background ||
        _paused.containsKey(current) ||
        outbox.isNotEmpty) {
      return false;
    }
    final result = await _dispatch(text);
    return result == _DispatchResult.completed ||
        result == _DispatchResult.admitted;
  }

  // Only the drain may bypass public FIFO admission for its captured head.
  Future<_DispatchResult> _dispatch(String text,
      {QueuedFollowup? source}) async {
    final session = source?.session ?? current;
    if (_disposed ||
        _loadFailed ||
        loading ||
        changingConnection ||
        busy ||
        _uncertain.containsKey(session) ||
        runPending ||
        unsavedChanges ||
        session == null ||
        text.trim().isEmpty) {
      return _DispatchResult.notDispatched;
    }
    final found = connections.where((c) => c['id'] == session.connectionId);
    if (found.isEmpty) {
      error =
          'This conversation’s connection is unavailable. Create a new conversation.';
      notifyListeners();
      return _DispatchResult.notDispatched;
    }
    final connection = source?.connection ?? found.single;
    final permission = _DispatchPermission(
        source ?? QueuedFollowup(text, session, connection));
    _preparing = permission;
    busy = true;
    error = null;
    pendingText = text;
    notifyListeners();
    var responseCompleted = false;
    var dispatched = false;
    SaathiCore? core;
    try {
      final runResult = await _sendRun(session, connection, text, permission);
      if (runResult != null) return runResult;
      core = await coreFor(connection);
      if (_disposed ||
          permission.revoked ||
          !_bound(permission.source) ||
          _paused.containsKey(session) ||
          _background ||
          _loadFailed ||
          !sessions.contains(session) ||
          !connections.any((c) => identical(c, connection))) {
        return _DispatchResult.notDispatched;
      }
      core.setSystemPrompt(session.systemPrompt);
      core.registerModel(
          ModelInfo(providerId: session.connectionId, name: session.model));
      core.selectModel('${session.connectionId}|${session.model}');
      core.restoreHistory(session.messages);
      _preparing = null;
      dispatched = true;
      final result = await core.sendMessage(text);
      responseCompleted = true;
      session.messages.addAll([
        ChatMessage(role: 'user', content: text),
        ChatMessage(role: 'model', content: result.text)
      ]);
      // Completion belongs to the captured session, not the selected tab.
      try {
        if (!_disposed) onReplyReceived?.call(session.id);
      } catch (_) {
        /* Optional OS notification must never fail a successful chat. */
      }
      try {
        await persist();
      } catch (_) {
        unsavedChanges = true;
        error =
            'Response received but not saved. Keep this conversation open and try saving again before closing Saathi.';
      }
      return _DispatchResult.completed;
    } on ProviderException catch (e) {
      error = e.message;
      return dispatched
          ? _DispatchResult.dispatchedUnknown
          : _DispatchResult.notDispatched;
    } catch (_) {
      if (runs[session.id] != null && !runs[session.id]!.committed) {
        _paused[session] =
            'Native outcome unconfirmed. Check status using the original operation; do not resend.';
        error = _paused[session];
        return _DispatchResult.admitted;
      }
      error =
          'Could not complete or save this response. Check your connection and secure storage.';
      return dispatched
          ? _DispatchResult.dispatchedUnknown
          : _DispatchResult.notDispatched;
    } finally {
      if (identical(_preparing, permission)) _preparing = null;
      core?.close();
      busy = false;
      pendingText = null;
      if (dispatched && !responseCompleted) {
        _uncertain[session] = QueuedFollowup(text, session, connection);
        _paused[session] =
            'Outcome unknown. The last request may have executed. It will not be sent again. Start a new conversation safely, or explicitly abandon this held outbox.';
      }
      if (!_draining && unsavedChanges) {
        pauseQueue(
            'Queue paused until the response is saved. Then choose Resume.',
            allSources: true);
      }
      notifyListeners();
      _scheduleSelectedQueue();
    }
  }
}
