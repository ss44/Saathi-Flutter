enum ProviderType { openai, anthropic, gemini, hermes, openclaw }

class ProviderConfig {
  const ProviderConfig(
      {required this.id,
      required this.name,
      required this.type,
      this.apiKey = '',
      this.baseUrl,
      this.modelFilter = '',
      this.useGrounding = false});
  final String id;
  final String name;
  final ProviderType type;
  final String apiKey;
  final String? baseUrl;
  final String modelFilter;
  final bool useGrounding;

  Map<String, dynamic> toJson({bool includeSecrets = false}) => {
        'id': id,
        'name': name,
        'type': type.name,
        'baseUrl': baseUrl,
        'modelFilter': modelFilter,
        'useGrounding': useGrounding,
        if (includeSecrets) 'apiKey': apiKey,
      };
  factory ProviderConfig.fromJson(Map<String, dynamic> json) => ProviderConfig(
        id: json['id'] as String,
        name: json['name'] as String,
        type: ProviderType.values.byName(json['type'] as String),
        apiKey: json['apiKey'] as String? ?? '',
        baseUrl: json['baseUrl'] as String?,
        modelFilter: json['modelFilter'] as String? ?? '',
        useGrounding: json['useGrounding'] == true,
      );
}

class ModelInfo {
  const ModelInfo(
      {required this.providerId, required this.name, String? displayName})
      : _displayName = displayName;
  final String providerId;
  final String name;
  final String? _displayName;
  String get displayName => _displayName ?? name;
  String get id => '$providerId|$name';
}

class ChatMessage {
  ChatMessage(
      {required this.role,
      required this.content,
      this.id,
      Map<String, dynamic> metadata = const {}})
      : metadata = Map.unmodifiable(metadata);
  final String role;
  final String content;
  final String? id;
  final Map<String, dynamic> metadata;
  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (id != null) 'id': id,
        'metadata': metadata
      };
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
      role: json['role'] as String,
      content: json['content'] as String,
      id: json['id'] as String?,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}));
}

class ChatResult {
  ChatResult(this.text, {Map<String, dynamic> metadata = const {}})
      : metadata = Map.unmodifiable(metadata);
  final String text;
  final Map<String, dynamic> metadata;
}

class ChatChunk {
  ChatChunk(this.text, {Map<String, dynamic> metadata = const {}})
      : metadata = Map.unmodifiable(metadata);
  final String text;
  final Map<String, dynamic> metadata;
}

class RemoteSession {
  RemoteSession(Map<String, dynamic> data) : data = Map.unmodifiable(data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get title => data['title'] as String? ?? id;
  String? get source => data['source'] as String?;
  String? get model => data['model'] as String?;

  /// This integration is read-only; foreign owners must use the native gateway.
  bool get canContinueViaRest => false;
}

class RemoteSessionPage {
  RemoteSessionPage(
      {required List<RemoteSession> sessions,
      required this.hasMore,
      required this.limit,
      required this.offset})
      : sessions = List.unmodifiable(sessions);
  final List<RemoteSession> sessions;
  final bool hasMore;
  final int limit;
  final int offset;
}

class RemoteHistoryPage {
  RemoteHistoryPage(
      {required this.sessionId,
      required List<Map<String, dynamic>> messages,
      required Map<String, dynamic> pagination})
      : messages = List.unmodifiable(
            messages.map((m) => Map<String, dynamic>.unmodifiable(m))),
        pagination = Map.unmodifiable(pagination);
  final String sessionId;
  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> pagination;
}

class ProviderException implements Exception {
  const ProviderException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() =>
      'ProviderException: $message${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}
