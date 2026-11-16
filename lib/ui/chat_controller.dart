import 'dart:async';
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

enum _DispatchResult { completed, dispatchedUnknown, notDispatched }

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
    if (_draining || busy || _disposed) return;
    _draining = true;
    try {
      while (outbox.isNotEmpty && !_disposed) {
        if (busy) break;
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
    onReplyReceived = null;
    super.dispose();
  }

  String? error, pendingText;
  ChatController(this.store, {CoreFactory? coreFactory})
      : coreFactory = coreFactory ?? (() => SaathiCore());
  Future<void> load() async {
    try {
      final data = await store.load();
      connections.addAll(data.connections);
      sessions.addAll(data.chats.map(ChatSession.fromJson));
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
      await store.saveConnection(c, apiKey: key);
      if (!_disposed) connections.add(c);
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
    try {
      await persist();
      error = null;
    } catch (_) {
      error =
          'Conversation is still not saved. Keep Saathi open and try again.';
    }
    notifyListeners();
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
    return await _dispatch(text) == _DispatchResult.completed;
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
