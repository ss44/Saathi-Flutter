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

class ChatController extends ChangeNotifier {
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
    final session = current;
    if (_disposed ||
        _loadFailed ||
        loading ||
        changingConnection ||
        busy ||
        session == null ||
        text.trim().isEmpty) {
      return false;
    }
    final found = connections.where((c) => c['id'] == session.connectionId);
    if (found.isEmpty) {
      error =
          'This conversation’s connection is unavailable. Create a new conversation.';
      notifyListeners();
      return false;
    }
    busy = true;
    error = null;
    pendingText = text;
    notifyListeners();
    SaathiCore? core;
    try {
      core = await coreFor(found.single);
      core.setSystemPrompt(session.systemPrompt);
      core.registerModel(
          ModelInfo(providerId: session.connectionId, name: session.model));
      core.selectModel('${session.connectionId}|${session.model}');
      core.restoreHistory(session.messages);
      final result = await core.sendMessage(text);
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
      return true;
    } on ProviderException catch (e) {
      error = e.message;
      return false;
    } catch (_) {
      error =
          'Could not complete or save this response. Check your connection and secure storage.';
      return false;
    } finally {
      core?.close();
      busy = false;
      pendingText = null;
      notifyListeners();
    }
  }
}
