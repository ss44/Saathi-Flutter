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
  Completer<void>? _activeAbort;
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
    _setSelection(compoundId);
  }

  void registerModel(ModelInfo model) {
    _provider(model.providerId);
    if (model.name.isEmpty) throw ArgumentError('Model name must be nonempty');
    _models[model.id] = model;
    _ensureSelection();
  }

  void _ensureSelection() {
    if (!_models.containsKey(_selected)) {
      _setSelection(_models.keys.firstOrNull);
    }
  }

  void _setSelection(String? id) {
    // Provider IDs cannot contain pipes. Preserve ownership even after the old
    // selected model has been removed from the catalog.
    final previousProvider = _selected?.split('|').first;
    _selected = id;
    if (previousProvider != null &&
        previousProvider != currentModel?.providerId) {
      clearHistory();
    }
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

  Future<List<ModelInfo>> discoverModels(String providerId,
      {bool Function()? isCurrent}) async {
    final config = _provider(providerId);
    if (config.type == ProviderType.hermes) {
      return _discoverHermesModels(config, isCurrent: isCurrent);
    }
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

  Future<List<ModelInfo>> _discoverHermesModels(ProviderConfig config,
      {bool Function()? isCurrent}) async {
    void check() {
      if ((isCurrent != null && !isCurrent()) ||
          !identical(_providers[config.id], config)) {
        throw StateError('Stale catalog');
      }
    }

    check();
    final capabilities = await discoverCapabilities(config.id);
    check();
    final endpoint = capabilities['endpoints']?['model_options'];
    if (capabilities['features']?['model_options'] != true ||
        endpoint is! Map ||
        endpoint['method'] != 'GET' ||
        endpoint['path'] != '/api/model/options') {
      throw const ProviderException(
          'This server does not advertise a model catalog. Update Hermes or check the original server configuration.');
    }
    final payload =
        await _json(config, '/api/model/options?include_unconfigured=false');
    check();
    final discovered = <String, ModelInfo>{};
    if (payload is! Map || payload['providers'] is! List) {
      throw const ProviderException(
          'Invalid model catalog. Check or update the Hermes server.');
    }
    for (final row in payload['providers']) {
      if (row is! Map ||
          row['slug'] is! String ||
          (row['slug'] as String).trim().isEmpty ||
          row['models'] is! List) {
        throw const ProviderException(
            'Invalid model catalog. Check or update the Hermes server.');
      }
      if (row['authenticated'] == false) continue;
      for (final name in row['models']) {
        if (name is! String || name.trim().isEmpty) {
          throw const ProviderException(
              'Invalid model catalog. Check or update the Hermes server.');
        }
        final model = ModelInfo(
            providerId: config.id,
            name: name,
            upstreamProvider: row['slug'],
            displayName:
                '${row['name'] is String ? row['name'] : row['slug']} · $name');
        discovered[model.id] = model;
      }
    }
    check();
    _models.removeWhere((_, model) => model.providerId == config.id);
    _models.addAll(discovered);
    _ensureSelection();
    return List.unmodifiable(discovered.values);
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
    final (path, body) = _buildDirectRequest(
      config,
      model,
      messages,
      effectiveSystem: effectiveSystem,
      stream: false,
    );
    final json = await _json(config, path, body: body) as Map<String, dynamic>;
    return switch (config.type) {
      ProviderType.gemini => _parseGeminiJson(json),
      ProviderType.anthropic => _parseAnthropicJson(json),
      _ => _parseOpenAiJson(json),
    };
  }

  (String, Map<String, dynamic>) _buildDirectRequest(
    ProviderConfig config,
    ModelInfo model,
    List<ChatMessage> messages, {
    required String effectiveSystem,
    required bool stream,
  }) {
    if (config.type == ProviderType.gemini) {
      final rest = _conversation(messages);
      final action =
          stream ? 'streamGenerateContent?alt=sse' : 'generateContent';
      return (
        '/v1beta/models/${Uri.encodeComponent(model.name)}:$action',
        {
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
        },
      );
    }
    if (config.type == ProviderType.anthropic) {
      final rest = _conversation(messages);
      return (
        '/v1/messages',
        {
          'model': model.name,
          'max_tokens': 4096,
          if (stream) 'stream': true,
          if (effectiveSystem.isNotEmpty) 'system': effectiveSystem,
          'messages': rest,
        },
      );
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
    return (
      '/v1/chat/completions',
      {
        'model': model.name,
        if (config.type == ProviderType.hermes &&
            model.upstreamProvider != null)
          'provider': model.upstreamProvider,
        if (stream) 'stream': true,
        if (stream) 'stream_options': {'include_usage': true},
        'messages': wire,
      },
    );
  }

  bool _validTokenCount(Object? value) =>
      value is int && value >= 0 && value <= 1000000000;

  ChatResult _parseGeminiJson(Map<String, dynamic> json) {
    final candidates = json['candidates'] as List? ?? [];
    if (candidates.isEmpty) {
      throw const ProviderException('Provider returned no text response');
    }
    final candidate = candidates.first;
    final parts = candidate['content']?['parts'] as List? ?? [];
    final text = parts
        .where((p) => p is Map && p['thought'] != true)
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

  ChatResult _parseGeminiJsonList(List<dynamic> frames) {
    final output = StringBuffer();
    final metadata = <String, dynamic>{};
    for (final frame in frames) {
      if (frame is! Map<String, dynamic>) {
        throw const ProviderException(
            'Provider returned an invalid response object');
      }
      if (frame['error'] != null) {
        throw const ProviderException('Provider stream reported an error');
      }
      final candidates = frame['candidates'] as List? ?? [];
      if (candidates.isNotEmpty) {
        final candidate = candidates.first;
        final parts = candidate['content']?['parts'] as List? ?? [];
        for (final p in parts) {
          if (p is Map && p['thought'] != true && p['text'] is String) {
            output.write(p['text'] as String);
          }
        }
        if (candidate['groundingMetadata'] != null) {
          metadata['groundingMetadata'] = candidate['groundingMetadata'];
        }
        final finish = candidate['finishReason'];
        if (finish is String) {
          if (const {'ERROR', 'CANCELLED', 'CANCELED'}
              .contains(finish.toUpperCase())) {
            throw const ProviderException(
                'Provider turn failed or was cancelled');
          }
          metadata['finishReason'] = finish;
        }
      }
      final usage = frame['usageMetadata'] as Map? ?? {};
      if (usage['promptTokenCount'] != null) {
        metadata['promptTokens'] = usage['promptTokenCount'];
      }
      if (usage['candidatesTokenCount'] != null) {
        metadata['completionTokens'] = usage['candidatesTokenCount'];
      }
      if (usage['totalTokenCount'] != null) {
        metadata['totalTokens'] = usage['totalTokenCount'];
      }
    }
    if (output.isEmpty) {
      throw const ProviderException('Provider returned no text response');
    }
    return ChatResult(output.toString(), metadata: metadata);
  }

  ChatResult _parseAnthropicJson(Map<String, dynamic> json) {
    final content = json['content'] as List? ?? [];
    final text = content
        .where((part) => part is Map && part['type'] == 'text')
        .map((part) => part['text'] as String? ?? '')
        .join();
    if (text.isEmpty) {
      throw const ProviderException('Provider returned no text response');
    }
    final usage = json['usage'] as Map? ?? {};
    final input = usage['input_tokens'];
    final output = usage['output_tokens'];
    return ChatResult(text, metadata: {
      if (_validTokenCount(input)) 'promptTokens': input,
      if (_validTokenCount(output)) 'completionTokens': output,
      if (json['stop_reason'] != null) 'finishReason': json['stop_reason'],
    });
  }

  ChatResult _parseOpenAiJson(Map<String, dynamic> json) {
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

  Future<T> _raceCancel<T>(Future<T> future, Future<void>? cancelTrigger) {
    if (cancelTrigger == null) return future;
    final completer = Completer<T>();
    future.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    cancelTrigger.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const RequestCancelledException());
      }
    });
    return completer.future;
  }

  Stream<List<int>> _cancellableBytes(
    Stream<List<int>> source,
    Future<void>? cancelTrigger,
  ) {
    if (cancelTrigger == null) return source;
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? subscription;
    var finished = false;
    void finishCancelled() {
      if (finished) return;
      finished = true;
      unawaited(subscription?.cancel().catchError((Object _) {}));
      if (!controller.isClosed) {
        controller.addError(const RequestCancelledException());
        unawaited(controller.close());
      }
    }

    controller.onListen = () {
      subscription = source.listen(
        (chunk) {
          if (!finished && !controller.isClosed) controller.add(chunk);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!finished && !controller.isClosed) {
            finished = true;
            controller.addError(error, stackTrace);
            unawaited(controller.close());
          }
        },
        onDone: () {
          if (!finished && !controller.isClosed) {
            finished = true;
            unawaited(controller.close());
          }
        },
        cancelOnError: true,
      );
      cancelTrigger.then((_) => finishCancelled());
    };
    controller.onCancel = () {
      finished = true;
      return subscription?.cancel();
    };
    return controller.stream;
  }

  Stream<ChatChunk> _parseSseStream(
    ProviderType type,
    Stream<List<int>> bytes,
    StringBuffer output,
    Map<String, dynamic> metadata,
  ) async* {
    var done = false;
    await for (final event in decodeEvents(bytes)) {
      if (type == ProviderType.anthropic) {
        if (event.data.trim().isEmpty) continue;
        final dynamic json;
        try {
          json = jsonDecode(event.data);
        } on FormatException {
          throw const ProviderException(
              'Provider returned malformed streaming JSON');
        }
        if (json is! Map) {
          throw const ProviderException(
              'Provider returned malformed streaming JSON');
        }
        final kind =
            json['type'] is String ? json['type'] as String : event.event;
        if (event.event == 'error' ||
            kind == 'error' ||
            json['error'] != null) {
          throw const ProviderException('Provider stream reported an error');
        }
        if (kind == 'message_stop') {
          done = true;
          break;
        }
        var delta = '';
        var usageUpdated = false;
        if (kind == 'message_start') {
          final usage = json['message']?['usage'] as Map? ?? {};
          if (_validTokenCount(usage['input_tokens'])) {
            metadata['promptTokens'] = usage['input_tokens'];
            usageUpdated = true;
          }
          if (_validTokenCount(usage['output_tokens'])) {
            metadata['completionTokens'] = usage['output_tokens'];
            usageUpdated = true;
          }
        } else if (kind == 'content_block_start') {
          final block = json['content_block'];
          if (block is Map &&
              block['type'] == 'text' &&
              block['text'] is String) {
            delta = block['text'] as String;
          }
        } else if (kind == 'content_block_delta') {
          final deltaObj = json['delta'];
          if (deltaObj is Map &&
              deltaObj['type'] == 'text_delta' &&
              deltaObj['text'] is String) {
            delta = deltaObj['text'] as String;
          }
        } else if (kind == 'message_delta') {
          final deltaObj = json['delta'];
          if (deltaObj is Map) {
            final stopReason = deltaObj['stop_reason'];
            if (['error', 'cancelled'].contains(stopReason)) {
              throw const ProviderException(
                  'Provider turn failed or was cancelled');
            }
            if (stopReason != null) metadata['finishReason'] = stopReason;
          }
          final usage = json['usage'] as Map? ?? {};
          if (_validTokenCount(usage['input_tokens'])) {
            metadata['promptTokens'] = usage['input_tokens'];
            usageUpdated = true;
          }
          if (_validTokenCount(usage['output_tokens'])) {
            metadata['completionTokens'] = usage['output_tokens'];
            usageUpdated = true;
          }
        }
        output.write(delta);
        if (delta.isNotEmpty || usageUpdated) {
          yield ChatChunk(delta, metadata: metadata);
        }
        continue;
      }

      if (type == ProviderType.gemini) {
        if (event.data.trim() == '[DONE]') {
          done = true;
          break;
        }
        if (event.data.trim().isEmpty) continue;
        final dynamic json;
        try {
          json = jsonDecode(event.data);
        } on FormatException {
          throw const ProviderException(
              'Provider returned malformed streaming JSON');
        }
        if (json is! Map) {
          throw const ProviderException(
              'Provider returned malformed streaming JSON');
        }
        if (event.event == 'error' || json['error'] != null) {
          throw const ProviderException('Provider stream reported an error');
        }
        final candidates = json['candidates'] as List? ?? [];
        var delta = '';
        if (candidates.isNotEmpty) {
          final candidate = candidates.first;
          final parts = candidate['content']?['parts'] as List? ?? [];
          delta = parts
              .where((p) => p is Map && p['thought'] != true)
              .map((p) => p['text'] as String? ?? '')
              .join();
          if (candidate['groundingMetadata'] != null) {
            metadata['groundingMetadata'] = candidate['groundingMetadata'];
          }
          final finish = candidate['finishReason'];
          if (finish is String &&
              finish.isNotEmpty &&
              finish.toUpperCase() != 'FINISH_REASON_UNSPECIFIED') {
            if (const {'ERROR', 'CANCELLED', 'CANCELED'}
                .contains(finish.toUpperCase())) {
              throw const ProviderException(
                  'Provider turn failed or was cancelled');
            }
            metadata['finishReason'] = finish;
            done = true;
          }
        }
        final usage = json['usageMetadata'] as Map? ?? {};
        if (usage['promptTokenCount'] != null) {
          metadata['promptTokens'] = usage['promptTokenCount'];
        }
        if (usage['candidatesTokenCount'] != null) {
          metadata['completionTokens'] = usage['candidatesTokenCount'];
        }
        if (usage['totalTokenCount'] != null) {
          metadata['totalTokens'] = usage['totalTokenCount'];
        }
        output.write(delta);
        if (delta.isNotEmpty || usage.isNotEmpty) {
          yield ChatChunk(delta, metadata: metadata);
        }
        continue;
      }

      if (event.data.trim() == '[DONE]') {
        done = true;
        break;
      }
      if (event.data.trim().isEmpty) continue;
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
      if (json is! Map) {
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
        throw const ProviderException('Provider turn failed or was cancelled');
      }
      if (finish != null) metadata['finishReason'] = finish;
      final usage = json['usage'] as Map? ?? {};
      if (usage.isNotEmpty) {
        metadata['usage'] = Map<String, dynamic>.from(usage);
      }
      if (json['runtime'] != null) metadata['runtime'] = json['runtime'];
      if (json['hermes'] != null) metadata['hermes'] = json['hermes'];
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
      throw const ProviderException('Provider stream ended before completion');
    }
    if (output.isEmpty) {
      throw const ProviderException('Provider returned no text response');
    }
  }

  /// Streams a direct-model or Hermes reply progressively over SSE, falling back
  /// cleanly when a provider returns a non-streaming JSON body.
  ///
  /// Completing [cancelTrigger] aborts the underlying HTTP request immediately
  /// and terminates the stream with [RequestCancelledException] without
  /// committing partial output to [history].
  Stream<ChatChunk> streamMessage(
    String text, {
    Future<void>? cancelTrigger,
  }) async* {
    if (_busy) throw StateError('A conversation request is already active');
    if (text.trim().isEmpty) throw ArgumentError('Message must not be empty');
    final model = currentModel ?? (throw StateError('No model selected'));
    final config = _provider(model.providerId);
    if (config.type == ProviderType.openclaw) {
      throw const ProviderException(
          'OpenClaw requires its native gateway WebSocket protocol');
    }
    _busy = true;
    final revision = _revision;
    final output = StringBuffer();
    final metadata = <String, dynamic>{};
    final abort = Completer<void>();
    _activeAbort = abort;
    var cancelled = false;
    if (cancelTrigger != null) {
      unawaited(cancelTrigger.then((_) {
        cancelled = true;
        if (!abort.isCompleted) abort.complete();
      }));
    }
    try {
      final messages = [...history, ChatMessage(role: 'user', content: text)];
      final (path, body) = _buildDirectRequest(
        config,
        model,
        messages,
        effectiveSystem: _systemPrompt,
        stream: true,
      );
      final request = http.AbortableRequest('POST', _uri(config, path),
          abortTrigger: abort.future);
      request.headers
          .addAll({..._headers(config), 'accept': 'text/event-stream'});
      request.followRedirects = false;
      request.body = jsonEncode(body);
      final response = await _raceCancel(
        _client.send(request).timeout(_requestTimeout),
        cancelTrigger,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!abort.isCompleted) abort.complete();
        throw ProviderException('Provider streaming request failed',
            statusCode: response.statusCode);
      }
      final contentType =
          (response.headers['content-type'] ?? '').toLowerCase();
      final bytesStream = _bounded(
        _cancellableBytes(response.stream, cancelTrigger),
      );
      if (contentType.contains('text/event-stream')) {
        await for (final chunk
            in _parseSseStream(config.type, bytesStream, output, metadata)) {
          yield chunk;
        }
        if (cancelled) throw const RequestCancelledException();
        if (revision == _revision) {
          _commit(text, ChatResult(output.toString(), metadata: metadata));
        }
      } else {
        final bytes = await bytesStream.expand((chunk) => chunk).toList();
        final raw = utf8.decode(bytes);
        final trimmed = raw.trimLeft();
        if (trimmed.startsWith('data:') ||
            trimmed.startsWith('event:') ||
            trimmed.startsWith(':')) {
          await for (final chunk in _parseSseStream(
            config.type,
            Stream<List<int>>.value(bytes),
            output,
            metadata,
          )) {
            yield chunk;
          }
          if (cancelled) throw const RequestCancelledException();
          if (revision == _revision) {
            _commit(text, ChatResult(output.toString(), metadata: metadata));
          }
        } else {
          final dynamic decoded;
          try {
            decoded = jsonDecode(raw);
          } on FormatException {
            throw const ProviderException('Provider returned invalid JSON');
          }
          final ChatResult result;
          if (decoded is List && config.type == ProviderType.gemini) {
            result = _parseGeminiJsonList(decoded);
          } else if (decoded is Map<String, dynamic>) {
            result = switch (config.type) {
              ProviderType.gemini => _parseGeminiJson(decoded),
              ProviderType.anthropic => _parseAnthropicJson(decoded),
              _ => _parseOpenAiJson(decoded),
            };
          } else {
            throw const ProviderException(
                'Provider returned an invalid response object');
          }
          if (cancelled) throw const RequestCancelledException();
          yield ChatChunk(result.text, metadata: result.metadata);
          if (revision == _revision) {
            _commit(text, result);
          }
        }
      }
    } on RequestCancelledException {
      rethrow;
    } on ProviderException {
      if (cancelled) throw const RequestCancelledException();
      rethrow;
    } on TimeoutException {
      if (cancelled) throw const RequestCancelledException();
      throw const ProviderException('Provider stream timed out');
    } on Exception {
      if (cancelled) throw const RequestCancelledException();
      throw const ProviderException('Provider streaming transport failed');
    } finally {
      if (identical(_activeAbort, abort)) _activeAbort = null;
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
    if (_activeAbort != null && !_activeAbort!.isCompleted) {
      _activeAbort!.complete();
    }
    if (_ownsClient) _client.close();
  }
}
