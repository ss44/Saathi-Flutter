import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart';

void main() {
  test(
      'Hermes app chat preserves runtime metadata but never attaches a browsed CLI session',
      () async {
    var deny = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.uri.path, '/v1/chat/completions');
      expect(request.headers.value('x-hermes-session-id'), isNull);
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      expect(body.containsKey('session_id'), false);
      expect(body['messages'], [
        {'role': 'user', 'content': 'synthetic app turn'}
      ]);
      request.response.headers.contentType = ContentType.json;
      request.response.statusCode = deny ? 409 : 200;
      request.response.write(jsonEncode(deny
          ? {
              'error': {'code': 'permission_denied', 'message': 'private error'}
            }
          : {
              'choices': [
                {
                  'message': {'content': 'synthetic answer'},
                  'finish_reason': 'length'
                }
              ],
              'runtime': {
                'provider': 'local',
                'model': 'test',
                'route_source': 'global'
              },
              'hermes': {'error_code': 'iteration_budget_exhausted'},
              'usage': {
                'prompt_tokens': 5,
                'completion_tokens': 2,
                'total_tokens': 7,
                'prompt_tokens_details': {'cached_tokens': 3}
              }
            }));
      await request.response.close();
    });
    final core = SaathiCore();
    addTearDown(() async {
      core.close();
      await server.close(force: true);
    });
    core.addProvider(ProviderConfig(
        id: 'h',
        name: 'Hermes',
        type: ProviderType.hermes,
        baseUrl: 'http://127.0.0.1:${server.port}'));
    core.registerModel(const ModelInfo(providerId: 'h', name: 'hermes-agent'));
    final result = await core
        .sendRaw([ChatMessage(role: 'user', content: 'synthetic app turn')]);
    expect(result.metadata['runtime']['provider'], 'local');
    expect(
        result.metadata['hermes']['error_code'], 'iteration_budget_exhausted');
    expect(
        result.metadata['usage']['prompt_tokens_details']['cached_tokens'], 3);
    expect(result.metadata['finishReason'], 'length');
    deny = true;
    await expectLater(
        core.sendMessage('synthetic app turn'),
        throwsA(isA<ProviderException>()
            .having((e) => e.statusCode, 'ownership', 409)));
    expect(core.history, isEmpty);
  });

  test(
      'native Hermes capabilities and paginated read-only remote history use official routes',
      () async {
    final paths = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      paths.add(request.uri.path);
      expect(request.method, 'GET');
      expect(request.headers.value('authorization'), 'Bearer synthetic');
      request.response.headers.contentType = ContentType.json;
      switch (request.uri.path) {
        case '/p/dev/v1/capabilities':
          request.response.write(jsonEncode({
            'features': {
              'session_list': true,
              'session_messages': true,
              'run_submission': true
            }
          }));
        case '/p/dev/api/sessions':
          expect(request.uri.queryParameters, {
            'limit': '2',
            'offset': '4',
            'source': 'cli',
            'include_children': 'false'
          });
          request.response.write(jsonEncode({
            'data': [
              {
                'id': 'cli-1',
                'source': 'cli',
                'title': 'Open chat',
                'model': 'local',
                'message_count': 2
              }
            ],
            'has_more': true,
            'limit': 2,
            'offset': 4
          }));
        case '/p/dev/api/sessions/cli-1/messages':
          expect(request.uri.queryParameters, {
            'limit': '100',
            'offset': '0',
            'order': 'oldest',
            'include_compacted': 'false',
            'inline_images': 'false'
          });
          request.response.write(jsonEncode({
            'session_id': 'cli-1-compressed',
            'data': [
              {
                'id': 1,
                'role': 'tool',
                'content': 'synthetic result',
                'tool_call_id': 'x'
              },
              {
                'id': 2,
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'synthetic'}
                ]
              }
            ],
            'pagination': {
              'limit': 100,
              'offset': 0,
              'returned': 2,
              'order': 'oldest'
            }
          }));
        default:
          request.response.statusCode = 404;
      }
      await request.response.close();
    });
    final core = SaathiCore();
    addTearDown(() async {
      core.close();
      await server.close(force: true);
    });
    core.addProvider(ProviderConfig(
        id: 'h',
        name: 'Hermes',
        type: ProviderType.hermes,
        apiKey: 'synthetic',
        baseUrl: 'http://127.0.0.1:${server.port}/p/dev/v1'));
    expect((await core.discoverCapabilities('h'))['features']['session_list'],
        true);
    final page =
        await core.listRemoteSessions('h', limit: 2, offset: 4, source: 'cli');
    expect(page.sessions.single.id, 'cli-1');
    expect(page.sessions.single.title, 'Open chat');
    expect(page.sessions.single.canContinueViaRest, false);
    expect(page.hasMore, true);
    expect(page.offset, 4);
    final history = await core.loadRemoteHistory('h', 'cli-1');
    expect(history.sessionId, 'cli-1-compressed');
    expect(history.messages.first['tool_call_id'], 'x');
    expect(history.pagination['returned'], 2);
    expect(core.history, isEmpty);
    expect(paths.length, 3);
  });
}
