import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';

void main() {
  test('Hermes streaming preserves the exact selected provider/model tuple',
      () async {
    Map<String, dynamic>? body;
    final core = SaathiCore(
        client: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
              'data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n',
              200,
              headers: {'content-type': 'text/event-stream'});
        }),
        systemPrompt: 'Be concise');
    core.addProvider(
        const ProviderConfig(id: 'h', name: 'h', type: ProviderType.hermes));
    core.registerModel(const ModelInfo(
        providerId: 'h', name: 'same', upstreamProvider: 'two'));
    expect(
        (await core.streamMessage('hello').toList()).map((c) => c.text).join(),
        'ok');
    expect(body, {
      'model': 'same',
      'provider': 'two',
      'stream': true,
      'stream_options': {'include_usage': true},
      'messages': [
        {'role': 'system', 'content': 'Be concise'},
        {'role': 'user', 'content': 'hello'}
      ]
    });
    core.close();
  });
  test(
      'Hermes inventory retains duplicate names by provider and dispatches tuple',
      () async {
    final paths = <String>[];
    final core = SaathiCore(client: MockClient((r) async {
      paths.add(r.url.path);
      if (r.url.path == '/v1/capabilities') {
        return http.Response(
            jsonEncode({
              'features': {'model_options': true},
              'endpoints': {
                'model_options': {'method': 'GET', 'path': '/api/model/options'}
              }
            }),
            200);
      }
      if (r.url.path == '/api/model/options') {
        expect(r.url.queryParameters['include_unconfigured'], 'false');
        expect(r.headers['authorization'], 'Bearer synthetic');
        return http.Response(
            jsonEncode({
              'providers': [
                for (final slug in ['one', 'two'])
                  {
                    'slug': slug,
                    'name': slug,
                    'models': ['same'],
                    'api_url': 'https://never-contact.invalid'
                  }
              ]
            }),
            200);
      }
      if (r.method == 'POST') {
        expect(jsonDecode(r.body)['provider'], 'two');
        expect(jsonDecode(r.body)['model'], 'same');
        return http.Response('{"choices":[{"message":{"content":"ok"}}]}', 200);
      }
      return http.Response('{"data":[{"id":"hermes-agent"}]}', 200);
    }));
    core.addProvider(const ProviderConfig(
        id: 'server',
        name: 'Server',
        type: ProviderType.hermes,
        apiKey: 'synthetic',
        baseUrl: 'http://localhost:1234'));
    final models = await core.discoverModels('server');
    expect(models.length, 2);
    expect(models.map((m) => m.id).toSet().length, 2);
    core.selectModel(models.last.id);
    expect((await core.sendMessage('test')).text, 'ok');
    expect(paths,
        ['/v1/capabilities', '/api/model/options', '/v1/chat/completions']);
    core.close();
  });
}
