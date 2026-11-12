import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart';

void main() {
  test(
      'OpenAI sends bounded conversation and system prompt and commits only successful exchanges',
      () async {
    final bodies = <Map<String, dynamic>>[];
    var fail = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.uri.path, '/v1/chat/completions');
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.headers.contentType = ContentType.json;
      request.response.statusCode = fail ? 401 : 200;
      request.response.write(jsonEncode(fail
          ? {
              'error': {'message': 'secret must not leak'}
            }
          : {
              'choices': [
                {
                  'message': {'content': 'synthetic answer'},
                  'finish_reason': 'stop'
                }
              ],
              'usage': {
                'prompt_tokens': 2,
                'completion_tokens': 3,
                'total_tokens': 5
              }
            }));
      await request.response.close();
    });
    final core = SaathiCore(maxHistory: 3, systemPrompt: 'synthetic system');
    addTearDown(() async {
      core.close();
      await server.close(force: true);
    });
    core.addProvider(ProviderConfig(
        id: 'a',
        name: 'Local',
        type: ProviderType.openai,
        baseUrl: 'http://127.0.0.1:${server.port}'));
    core.registerModel(const ModelInfo(providerId: 'a', name: 'test'));
    final result = await core.sendMessage('synthetic first');
    expect(result.metadata['totalTokens'], 5);
    expect(core.history.length, 2);
    expect(core.history.last.role, 'model');
    await core.sendMessage('synthetic second');
    expect(core.history.map((m) => m.content),
        ['synthetic first', 'synthetic second', 'synthetic answer']);
    expect(bodies.last['messages'], [
      {'role': 'system', 'content': 'synthetic system'},
      {'role': 'user', 'content': 'synthetic first'},
      {'role': 'assistant', 'content': 'synthetic answer'},
      {'role': 'user', 'content': 'synthetic second'},
    ]);
    fail = true;
    await expectLater(
        core.sendMessage('failure'),
        throwsA(isA<ProviderException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.toString(), 'safe', isNot(contains('secret')))));
    expect(core.history.length, 3);
    core.setSystemPrompt('new synthetic system');
    expect(core.history, isEmpty);
    expect(core.systemPrompt, 'new synthetic system');
    expect(core.isBusy, false);
  });
  test(
      'discovery isolates same-named models across instances and refreshes stale entries',
      () async {
    var generation = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.uri.path, '/v1/models');
      expect(request.headers.value('authorization'),
          anyOf('Bearer fake-one', 'Bearer fake-two'));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'data': [
          {'id': generation == 0 ? 'tiny' : 'new'}
        ]
      }));
      await request.response.close();
    });
    final core = SaathiCore();
    addTearDown(() async {
      core.close();
      await server.close(force: true);
    });
    final root = 'http://127.0.0.1:${server.port}';
    core.addProvider(ProviderConfig(
        id: 'a',
        name: 'One',
        type: ProviderType.openai,
        baseUrl: '$root/v1/',
        apiKey: 'fake-one'));
    core.addProvider(ProviderConfig(
        id: 'b',
        name: 'Two',
        type: ProviderType.openai,
        baseUrl: root,
        apiKey: 'fake-two'));
    await core.discoverModels('a');
    await core.discoverModels('b');
    expect(core.models.map((m) => m.id), ['a|tiny', 'b|tiny']);
    core.selectModel('b|tiny');
    generation++;
    await core.discoverModels('a');
    expect(core.models.map((m) => m.id), ['b|tiny', 'a|new']);
    expect(core.currentModel?.id, 'b|tiny');
    core.removeProvider('b');
    expect(core.currentModel?.id, 'a|new');
  });
  test('config round trips without leaking credentials by default', () {
    final config = ProviderConfig(
        id: 'one',
        name: 'Local',
        type: ProviderType.openai,
        apiKey: 'test-secret',
        baseUrl: 'http://localhost:9',
        modelFilter: 'tiny',
        useGrounding: true);
    expect(config.toJson().containsKey('apiKey'), false);
    final restored =
        ProviderConfig.fromJson(config.toJson(includeSecrets: true));
    expect(restored.id, 'one');
    expect(restored.apiKey, 'test-secret');
    expect(restored.modelFilter, 'tiny');
    expect(restored.useGrounding, true);
    expect(ModelInfo(providerId: 'one', name: 'tiny').id, 'one|tiny');
    final message = ChatMessage.fromJson(const {
      'role': 'model',
      'content': 'test',
      'metadata': {'totalTokens': 3}
    });
    expect(message.toJson()['metadata'], {'totalTokens': 3});
  });
}
