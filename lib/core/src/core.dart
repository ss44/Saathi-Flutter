import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'sse.dart';

class SaathiCore {
  SaathiCore(
      {http.Client? client,
      int maxHistory = 20,
      String systemPrompt = '',
      Duration requestTimeout = const Duration(seconds: 60),
      int maxResponseBytes = 8 * 1024 * 1024})
      : _client = client ?? http.Client(),
        _requestTimeout = requestTimeout,
        _maxResponseBytes = maxResponseBytes,
        _ownsClient = client == null,
        _maxHistory = maxHistory,
        _systemPrompt = systemPrompt {
    if (maxHistory < 1) throw ArgumentError('maxHistory must be positive');
    if (requestTimeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError('Request bounds must be positive');
    }
  }
  final Duration _requestTimeout;
  final int _maxResponseBytes;
  int _maxHistory;
  String _systemPrompt;
  bool _busy = false;
  int _revision = 0;
  int _messageSeq = 0;
  final List<ChatMessage> _history = [];
  List<ChatMessage> get history => List.unmodifiable(_history);
  String get systemPrompt => _systemPrompt;
  bool get isBusy => _busy;
  void setMaxHistory(int max) {
    if (max < 1) throw ArgumentError('maxHistory must be positive');
    _maxHistory = max;
    _prune();
  }

  void _prune() {
    if (_history.length > _maxHistory) {
      final first = _history.first;
      final tail = _maxHistory == 1
          ? <ChatMessage>[]
          : _history.sublist(_history.length - _maxHistory + 1);
      _history
        ..clear()
        ..add(first)
        ..addAll(tail);
    }
  }

  void clearHistory() {
    _revision++;
    _history.clear();
  }

  void restoreHistory(List<ChatMessage> messages) {
    _revision++;
    _history
      ..clear()
      ..addAll(messages);
    _prune();
  }

  void setSystemPrompt(String prompt) {
    _systemPrompt = prompt;
    clearHistory();
  }

  void _commit(String text, ChatResult result) {
    _history
        .add(ChatMessage(role: 'user', content: text, id: 'm${++_messageSeq}'));
    _history.add(ChatMessage(
        role: 'model',
        content: result.text,
        id: 'm${++_messageSeq}',
        metadata: result.metadata));
    _prune();
  }

  final http.Client _client;
  final bool _ownsClient;
  final Map<String, ProviderConfig> _providers = {};
  final Map<String, ModelInfo> _models = {};
  String? _selected;
  List<ProviderConfig> get providers => List.unmodifiable(_providers.values);
  List<ModelInfo> get models => List.unmodifiable(_models.values);
  ModelInfo? get currentModel => _models[_selected];

  void addProvider(ProviderConfig config) {
    if (_busy) {
      throw StateError(
          'Cannot reconfigure providers during an active conversation');
    }
    if (config.baseUrl != null) _validateRoot(config.baseUrl!);
    if (config.id.isEmpty || config.id.contains('|')) {
      throw ArgumentError.value(
          config.id, 'id', 'Must be nonempty and contain no pipe');
    }
    final previous = _providers[config.id];
    if (previous != null &&
        (previous.type != config.type ||
            previous.baseUrl != config.baseUrl ||
            previous.apiKey != config.apiKey)) {
      clearHistory();
      _models.removeWhere((_, model) => model.providerId == config.id);
      _ensureSelection();
    }
    _providers[config.id] = config;
  }

  void removeProvider(String id) {
    if (_busy) {
      throw StateError('Cannot remove providers during an active conversation');
    }
    _providers.remove(id);
    _models.removeWhere((_, model) => model.providerId == id);
    _ensureSelection();
  }

  void selectModel(String compoundId) {
    if (_busy) {
      throw StateError('Cannot select a model during an active conversation');
    }
    if (!_models.containsKey(compoundId)) throw StateError('Model not loaded');
    _selected = compoundId;
  }

  void registerModel(ModelInfo model) {
    _provider(model.providerId);
    if (model.name.isEmpty) throw ArgumentError('Model name must be nonempty');
    _models[model.id] = model;
    _ensureSelection();
  }

  void _ensureSelection() {
    if (!_models.containsKey(_selected)) _selected = _models.keys.firstOrNull;
  }

  ProviderConfig _provider(String id) =>
      _providers[id] ?? (throw StateError('Provider not configured'));

  void _validateRoot(String root) {
    final Uri? uri;
    try {
      uri = Uri.tryParse(root);
    } on FormatException {
      throw ArgumentError('Invalid provider base URL');
    }
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme == 'http' &&
            !['localhost', '127.0.0.1', '::1', '[::1]'].contains(uri.host))) {
      throw ArgumentError(
          'Provider base URL requires HTTPS (HTTP only on loopback), without userinfo, query or fragment');
    }
  }

  Uri _uri(ProviderConfig config, String path) {
    final defaultRoot = switch (config.type) {
      ProviderType.openai => 'https://api.openai.com',
      ProviderType.anthropic => 'https://api.anthropic.com',
      ProviderType.gemini => 'https://generativelanguage.googleapis.com',
      ProviderType.hermes => 'http://127.0.0.1:8642',
      ProviderType.openclaw => throw const ProviderException(
          'OpenClaw requires its native gateway WebSocket protocol'),
    };
    var root = (config.baseUrl ?? defaultRoot).replaceFirst(RegExp(r'/+$'), '');
    if (root.endsWith('/v1') &&
        (path.startsWith('/v1/') || path.startsWith('/api/'))) {
      root = root.substring(0, root.length - 3);
    }
    if (root.endsWith('/v1beta') && path.startsWith('/v1beta/')) {
      root = root.substring(0, root.length - 7);
    }
    final uri = Uri.parse('$root$path');
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw ArgumentError('Invalid provider base URL');
    }
    return uri;
  }

  Map<String, String> _headers(ProviderConfig config) => {
        'content-type': 'application/json',
        if (config.type == ProviderType.anthropic)
          'anthropic-version': '2023-06-01',
        if (config.apiKey.isNotEmpty)
          switch (config.type) {
            ProviderType.anthropic => 'x-api-key',
            ProviderType.gemini => 'x-goog-api-key',
            _ => 'authorization',
          }: [ProviderType.anthropic, ProviderType.gemini].contains(config.type)
              ? config.apiKey
              : 'Bearer ${config.apiKey}',
      };
  Stream<List<int>> _bounded(Stream<List<int>> stream) async* {
    var count = 0;
    await for (final bytes in stream.timeout(_requestTimeout)) {
      count += bytes.length;
      if (count > _maxResponseBytes) {
        throw const ProviderException('Provider response exceeded size limit');
      }
      yield bytes;
    }
  }

  Future<dynamic> _json(ProviderConfig config, String path,
      {Map<String, dynamic>? body}) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
        body == null ? 'GET' : 'POST', _uri(config, path),
        abortTrigger: abort.future);
    request.headers.addAll(_headers(config));
    request.followRedirects = false;
    if (body != null) request.body = jsonEncode(body);
    try {
      return await (() async {
        final response = await _client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (!abort.isCompleted) abort.complete();
          throw ProviderException(
              response.statusCode == 409
                  ? 'Session ownership or admission conflict; existing desktop/CLI sessions require gateway attachment'
                  : 'Provider request failed',
              statusCode: response.statusCode);
        }
        final bytes =
            await _bounded(response.stream).expand((chunk) => chunk).toList();
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map<String, dynamic>) {
          throw const ProviderException(
              'Provider returned an invalid response object');
        }
        return decoded;
      })()
          .timeout(_requestTimeout);
    } on ProviderException {
      rethrow;
    } on TimeoutException {
      throw const ProviderException('Provider request timed out');
    } on FormatException {
      throw const ProviderException('Provider returned invalid JSON');
    } on Exception {
      throw const ProviderException('Provider transport request failed');
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<List<ModelInfo>> discoverModels(String providerId) async {
    final config = _provider(providerId);
    final isGemini = config.type == ProviderType.gemini;
    final json =
        await _json(config, isGemini ? '/v1beta/models' : '/v1/models');
    final rows =
        (json as Map<String, dynamic>)[isGemini ? 'models' : 'data'] as List? ??
            [];
    final terms = config.modelFilter
        .toLowerCase()
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final discovered = <ModelInfo>[];
    for (final row in rows) {
      if (isGemini &&
          !(row['supportedGenerationMethods'] as List? ?? [])
              .contains('generateContent')) {
        continue;
      }
      final name = isGemini
          ? (row['name'] as String).replaceFirst(RegExp(r'^models/'), '')
          : row['id'] as String;
      final model = ModelInfo(
          providerId: providerId,
          name: name,
          displayName:
              row[isGemini ? 'displayName' : 'display_name'] as String?);
      if (terms.isEmpty ||
          terms.any((term) => model.displayName.toLowerCase().contains(term))) {
        discovered.add(model);
      }
    }
    if (!identical(_providers[providerId], config)) {
      throw StateError('Provider changed during discovery');
    }
    _models.removeWhere((_, model) => model.providerId == providerId);
    for (final model in discovered) {
      _models[model.id] = model;
    }
    _ensureSelection();
    return List.unmodifiable(discovered);
  }

  Future<ChatResult> sendMessage(String text) async {
    if (_busy) throw StateError('A conversation request is already active');
    if (text.trim().isEmpty) throw ArgumentError('Message must not be empty');
    _busy = true;
    final revision = _revision;
    try {
      final result =
          await sendRaw([...history, ChatMessage(role: 'user', content: text)]);
      if (revision == _revision) _commit(text, result);
      return result;
    } finally {
      _busy = false;
    }
  }

  Future<ChatResult> sendRaw(List<ChatMessage> messages,
      {String? modelId}) async {
    final model = _models[modelId ?? _selected] ??
        (throw StateError('No model selected'));
    final config = _provider(model.providerId);
    if (config.type == ProviderType.openclaw) {
      throw const ProviderException(
          'OpenClaw requires its native gateway WebSocket protocol');
    }
    final system = messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n\n');
    final effectiveSystem =
        messages.any((m) => m.role == 'system') ? system : _systemPrompt;
    if (config.type == ProviderType.gemini) {
      final rest = _conversation(messages);
      final json = await _json(config,
          '/v1beta/models/${Uri.encodeComponent(model.name)}:generateContent',
          body: {
            'contents': [
              for (final message in rest)
                {
                  'role': message['role'] == 'assistant' ? 'model' : 'user',
                  'parts': [
                    {'text': message['content']}
                  ]
                }
            ],
            if (effectiveSystem.isNotEmpty)
              'system_instruction': {
                'parts': [
                  {'text': effectiveSystem}
                ]
              },
            if (config.useGrounding)
              'tools': [
                {'googleSearch': <String, dynamic>{}}
              ],
          });
      final candidates = json['candidates'] as List? ?? [];
      if (candidates.isEmpty) {
        throw const ProviderException('Provider returned no text response');
      }
      final candidate = candidates.first;
      final parts = candidate['content']?['parts'] as List? ?? [];
      final text = parts
          .where((p) => p['thought'] != true)
          .map((p) => p['text'] as String? ?? '')
          .join();
      if (text.isEmpty) {
        throw const ProviderException('Provider returned no text response');
      }
      final usage = json['usageMetadata'] as Map? ?? {};
      return ChatResult(text, metadata: {
        if (usage['promptTokenCount'] != null)
          'promptTokens': usage['promptTokenCount'],
        if (usage['candidatesTokenCount'] != null)
          'completionTokens': usage['candidatesTokenCount'],
        if (usage['totalTokenCount'] != null)
          'totalTokens': usage['totalTokenCount'],
        if (candidate['groundingMetadata'] != null)
          'groundingMetadata': candidate['groundingMetadata'],
        if (candidate['finishReason'] != null)
          'finishReason': candidate['finishReason'],
      });
    }
    if (config.type == ProviderType.anthropic) {
      final rest = _conversation(messages);
      final json = await _json(config, '/v1/messages', body: {
        'model': model.name,
        'max_tokens': 4096,
        if (effectiveSystem.isNotEmpty) 'system': effectiveSystem,
        'messages': rest,
      });
      final content = json['content'] as List? ?? [];
      final text = content
          .where((part) => part['type'] == 'text')
          .map((part) => part['text'] as String? ?? '')
          .join();
      if (text.isEmpty) {
        throw const ProviderException('Provider returned no text response');
      }
      final usage = json['usage'] as Map? ?? {};
      final input = usage['input_tokens'] as int? ?? 0;
      final output = usage['output_tokens'] as int? ?? 0;
      return ChatResult(text, metadata: {
        'promptTokens': input,
        'completionTokens': output,
        'totalTokens': input + output,
        if (json['stop_reason'] != null) 'finishReason': json['stop_reason']
      });
    }
    final wire = <Map<String, dynamic>>[
      if (effectiveSystem.isNotEmpty)
        {'role': 'system', 'content': effectiveSystem},
      for (final message in messages.where((m) => m.role != 'system'))
        {
          'role': message.role == 'model' ? 'assistant' : message.role,
          'content': message.content
        },
    ];
    final json = await _json(config, '/v1/chat/completions',
        body: {'model': model.name, 'messages': wire});
    final choices = json['choices'] as List? ?? [];
    if (choices.isEmpty || choices.first['message']?['content'] is! String) {
      throw const ProviderException('Provider returned no text response');
    }
    final choice = choices.first;
    if (['error', 'cancelled'].contains(choice['finish_reason'])) {
      throw const ProviderException('Provider turn failed or was cancelled');
    }
    final usage = json['usage'] as Map? ?? {};
    return ChatResult(choice['message']['content'] as String, metadata: {
      if (usage.isNotEmpty) 'usage': Map<String, dynamic>.from(usage),
      if (json['runtime'] != null) 'runtime': json['runtime'],
      if (json['hermes'] != null) 'hermes': json['hermes'],
      if (usage['prompt_tokens'] != null)
        'promptTokens': usage['prompt_tokens'],
      if (usage['completion_tokens'] != null)
        'completionTokens': usage['completion_tokens'],
      if (usage['total_tokens'] != null) 'totalTokens': usage['total_tokens'],
      if (choice['finish_reason'] != null)
        'finishReason': choice['finish_reason'],
    });
  }

  List<Map<String, dynamic>> _conversation(List<ChatMessage> messages) {
    final result = <Map<String, dynamic>>[];
    for (final message in messages.where((m) => m.role != 'system')) {
      final role = message.role == 'model' ? 'assistant' : message.role;
      if (!['user', 'assistant'].contains(role)) {
        throw ArgumentError('Unsupported chat role');
      }
      if (result.isNotEmpty && result.last['role'] == role) {
        result.last['content'] =
            '${result.last['content']}\n\n${message.content}';
      } else {
        result.add({'role': role, 'content': message.content});
      }
    }
    return result;
  }

  Stream<ChatChunk> streamMessage(String text) async* {
    if (_busy) throw StateError('A conversation request is already active');
    if (text.trim().isEmpty) throw ArgumentError('Message must not be empty');
    final model = currentModel ?? (throw StateError('No model selected'));
    final config = _provider(model.providerId);
    if (![ProviderType.openai, ProviderType.hermes].contains(config.type)) {
      throw const ProviderException(
          'Streaming is supported only for OpenAI-compatible and Hermes API servers');
    }
    _busy = true;
    final revision = _revision;
    final output = StringBuffer();
    final metadata = <String, dynamic>{};
    final abort = Completer<void>();
    try {
      final request = http.AbortableRequest(
          'POST', _uri(config, '/v1/chat/completions'),
          abortTrigger: abort.future);
      request.headers
          .addAll({..._headers(config), 'accept': 'text/event-stream'});
      request.followRedirects = false;
      request.body = jsonEncode({
        'model': model.name,
        'stream': true,
        'stream_options': {'include_usage': true},
        'messages': [
          if (_systemPrompt.isNotEmpty)
            {'role': 'system', 'content': _systemPrompt},
          ..._conversation(
              [...history, ChatMessage(role: 'user', content: text)])
        ],
      });
      final response = await _client.send(request).timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!abort.isCompleted) abort.complete();
        throw ProviderException('Provider streaming request failed',
            statusCode: response.statusCode);
      }
      var done = false;
      await for (final event in decodeEvents(_bounded(response.stream))) {
        if (event.data.trim() == '[DONE]') {
          done = true;
          break;
        }
        if (event.event.isNotEmpty &&
            event.event != 'message' &&
            event.event != 'error') {
          continue;
        }
        final dynamic json;
        try {
          json = jsonDecode(event.data);
        } on FormatException {
          throw const ProviderException(
              'Provider returned malformed streaming JSON');
        }
        if (event.event == 'error' || json['error'] != null) {
          throw const ProviderException('Provider stream reported an error');
        }
        final choices = json['choices'] as List? ?? [];
        final delta = choices.isEmpty
            ? ''
            : choices.first['delta']?['content'] as String? ?? '';
        final finish = choices.isEmpty ? null : choices.first['finish_reason'];
        if (['error', 'cancelled'].contains(finish)) {
          throw const ProviderException(
              'Provider turn failed or was cancelled');
        }
        if (finish != null) metadata['finishReason'] = finish;
        final usage = json['usage'] as Map? ?? {};
        if (usage['prompt_tokens'] != null) {
          metadata['promptTokens'] = usage['prompt_tokens'];
        }
        if (usage['completion_tokens'] != null) {
          metadata['completionTokens'] = usage['completion_tokens'];
        }
        if (usage['total_tokens'] != null) {
          metadata['totalTokens'] = usage['total_tokens'];
        }
        output.write(delta);
        if (delta.isNotEmpty || usage.isNotEmpty) {
          yield ChatChunk(delta, metadata: metadata);
        }
      }
      if (!done) {
        throw const ProviderException(
            'Provider stream ended before completion');
      }
      if (output.isEmpty) {
        throw const ProviderException('Provider returned no text response');
      }
      if (revision == _revision) {
        _commit(text, ChatResult(output.toString(), metadata: metadata));
      }
    } on ProviderException {
      rethrow;
    } on TimeoutException {
      throw const ProviderException('Provider stream timed out');
    } on Exception {
      throw const ProviderException('Provider streaming transport failed');
    } finally {
      if (!abort.isCompleted) abort.complete();
      _busy = false;
    }
  }

  ProviderConfig _hermes(String providerId) {
    final config = _provider(providerId);
    if (config.type != ProviderType.hermes) {
      throw const ProviderException(
          'Native session inspection requires a Hermes API server');
    }
    return config;
  }

  Future<Map<String, dynamic>> discoverCapabilities(String providerId) async =>
      Map<String, dynamic>.unmodifiable(
          await _json(_hermes(providerId), '/v1/capabilities')
              as Map<String, dynamic>);

  Future<RemoteSessionPage> listRemoteSessions(String providerId,
      {int limit = 50,
      int offset = 0,
      String? source,
      bool includeChildren = false}) async {
    if (limit < 1 || limit > 200 || offset < 0) {
      throw ArgumentError('Invalid session pagination');
    }
    final query = Uri(queryParameters: {
      'limit': '$limit',
      'offset': '$offset',
      if (source != null) 'source': source,
      'include_children': '$includeChildren'
    }).query;
    final json = await _json(_hermes(providerId), '/api/sessions?$query')
        as Map<String, dynamic>;
    return RemoteSessionPage(
        sessions: [
          for (final row in json['data'] as List? ?? [])
            RemoteSession(Map<String, dynamic>.from(row as Map))
        ],
        hasMore: json['has_more'] == true,
        limit: json['limit'] as int? ?? limit,
        offset: json['offset'] as int? ?? offset);
  }

  Future<RemoteHistoryPage> loadRemoteHistory(
      String providerId, String sessionId,
      {int limit = 100, int offset = 0, bool includeCompacted = false}) async {
    if (sessionId.isEmpty || RegExp(r'[\x00-\x1f]').hasMatch(sessionId)) {
      throw ArgumentError('Invalid session ID');
    }
    if (limit < 1 || limit > 500 || offset < 0) {
      throw ArgumentError('Invalid message pagination');
    }
    final query = Uri(queryParameters: {
      'limit': '$limit',
      'offset': '$offset',
      'order': 'oldest',
      'include_compacted': '$includeCompacted',
      'inline_images': 'false'
    }).query;
    final json = await _json(_hermes(providerId),
            '/api/sessions/${Uri.encodeComponent(sessionId)}/messages?$query')
        as Map<String, dynamic>;
    return RemoteHistoryPage(
        sessionId: json['session_id'] as String? ?? sessionId,
        messages: [
          for (final row in json['data'] as List? ?? [])
            Map<String, dynamic>.from(row as Map)
        ],
        pagination:
            Map<String, dynamic>.from(json['pagination'] as Map? ?? {}));
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
