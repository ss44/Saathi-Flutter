import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart';

void main() {
  test('Gemini filters generation models and preserves grounding and usage',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('x-goog-api-key'), 'synthetic');
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        expect(request.uri.path, '/v1beta/models');
        request.response.write(jsonEncode({
          'models': [
            {
              'name': 'models/gemini-test',
              'displayName': 'Test Gemini',
              'supportedGenerationMethods': ['generateContent']
            },
            {
              'name': 'models/embed',
              'supportedGenerationMethods': ['embedContent']
            },
          ]
        }));
      } else {
        expect(request.uri.path, '/v1beta/models/gemini-test:generateContent');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['system_instruction'], {
          'parts': [
            {'text': 'synthetic system'}
          ]
        });
        expect(body['contents'], [
          {
            'role': 'user',
            'parts': [
              {'text': 'one\n\ntwo'}
            ]
          },
          {
            'role': 'model',
            'parts': [
              {'text': 'prior'}
            ]
          },
          {
            'role': 'user',
            'parts': [
              {'text': 'next'}
            ]
          }
        ]);
        expect(body['tools'], [
          {'googleSearch': {}}
        ]);
        request.response.write(jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'hidden', 'thought': true},
                  {'text': 'visible'},
                  {'text': ' text'}
                ]
              },
              'groundingMetadata': {
                'webSearchQueries': ['synthetic']
              },
              'finishReason': 'STOP'
            }
          ],
          'usageMetadata': {
            'promptTokenCount': 2,
            'candidatesTokenCount': 3,
            'totalTokenCount': 6
          }
        }));
      }
      await request.response.close();
    });
    final core = SaathiCore(systemPrompt: 'synthetic system');
    addTearDown(() async {
      core.close();
      await server.close(force: true);
    });
    core.addProvider(ProviderConfig(
        id: 'g',
        name: 'Gemini',
        type: ProviderType.gemini,
        apiKey: 'synthetic',
        baseUrl: 'http://127.0.0.1:${server.port}/v1beta',
        useGrounding: true));
    final models = await core.discoverModels('g');
    expect(models.single.name, 'gemini-test');
    final result = await core.sendRaw([
      ChatMessage(role: 'user', content: 'one'),
      ChatMessage(role: 'user', content: 'two'),
      ChatMessage(role: 'assistant', content: 'prior'),
      ChatMessage(role: 'user', content: 'next')
    ]);
    expect(result.text, 'visible text');
    expect(result.metadata['totalTokens'], 6);
    expect(result.metadata['groundingMetadata'], {
      'webSearchQueries': ['synthetic']
    });
  });
  test(
      'Anthropic discovers display names, merges roles, keeps system separate and usage',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('x-api-key'), 'synthetic');
      expect(request.headers.value('anthropic-version'), '2023-06-01');
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        expect(request.uri.path, '/v1/models');
        request.response.write(jsonEncode({
          'data': [
            {'id': 'claude-test', 'display_name': 'Small Claude'}
          ]
        }));
      } else {
        expect(request.uri.path, '/v1/messages');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['model'], 'claude-test');
        expect(body['system'], 'override\n\nsecond instruction');
        expect(body['max_tokens'], 4096);
        expect(body['messages'], [
          {'role': 'user', 'content': 'one\n\ntwo'},
          {'role': 'assistant', 'content': 'prior'},
          {'role': 'user', 'content': 'next'}
        ]);
        request.response.write(jsonEncode({
          'content': [
            {'type': 'thinking', 'thinking': 'hidden'},
            {'type': 'text', 'text': 'first'},
            {'type': 'text', 'text': 'second'}
          ],
          'usage': {'input_tokens': 7, 'output_tokens': 8},
          'stop_reason': 'end_turn'
        }));
      }
      await request.response.close();
    });
    final core = SaathiCore(systemPrompt: 'not used');
    addTearDown(() async {
      core.close();
      await server.close(force: true);
    });
    core.addProvider(ProviderConfig(
        id: 'a',
        name: 'Claude',
        type: ProviderType.anthropic,
        apiKey: 'synthetic',
        baseUrl: 'http://127.0.0.1:${server.port}',
        modelFilter: 'small'));
    expect((await core.discoverModels('a')).single.displayName, 'Small Claude');
    final result = await core.sendRaw([
      ChatMessage(role: 'system', content: 'override'),
      ChatMessage(role: 'system', content: 'second instruction'),
      ChatMessage(role: 'user', content: 'one'),
      ChatMessage(role: 'user', content: 'two'),
      ChatMessage(role: 'model', content: 'prior'),
      ChatMessage(role: 'user', content: 'next'),
    ]);
    expect(result.text, 'firstsecond');
    expect(result.metadata['promptTokens'], 7);
    expect(result.metadata['completionTokens'], 8);
    expect(result.metadata['totalTokens'], 15);
    expect(core.history, isEmpty);
  });
}
