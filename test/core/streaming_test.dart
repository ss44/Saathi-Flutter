import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart';

void main() {
  for (final terminal in ['truncated', 'error', 'cancelled']) {
    test('partial stream with $terminal terminal does not persist a reply',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        request.response
            .write('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');
        if (terminal != 'truncated') {
          request.response.write(
              'data: {"choices":[{"delta":{},"finish_reason":"$terminal"}]}\n\ndata: [DONE]\n\n');
        }
        await request.response.close();
      });
      final core = SaathiCore();
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
      await expectLater(core.streamMessage('synthetic').toList(),
          throwsA(isA<ProviderException>()));
      expect(core.history, isEmpty);
      expect(core.isBusy, false);
    });
  }

  test(
      'canceling streamed subscription releases busy state without appending partial history',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response
          .write('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await request.response.close();
    });
    final core = SaathiCore();
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
    expect((await core.streamMessage('synthetic').take(1).toList()).single.text,
        'partial');
    expect(core.history, isEmpty);
    expect(core.isBusy, false);
  });

  test('stream idle deadline aborts safely and never persists partial output',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response
          .write('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await request.response.close();
    });
    final core = SaathiCore(requestTimeout: const Duration(milliseconds: 50));
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
    await expectLater(
        core.streamMessage('synthetic').toList(),
        throwsA(isA<ProviderException>()
            .having((e) => e.message, 'bounded', contains('timed out'))));
    expect(core.history, isEmpty);
    expect(core.isBusy, false);
  });

  test(
      'OpenAI SSE handles split UTF8, multiline data, usage-only frames and tool events',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      expect(body['stream'], true);
      expect(body['stream_options'], {'include_usage': true});
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      // Write deliberately one byte at a time, including the Unicode scalar.
      final payload = utf8.encode(
          ': keepalive\r\n\r\nevent: hermes.tool.progress\ndata: {"tool":"synthetic"}\n\ndata: {"choices":\ndata: [{"delta":{"content":"ह"}}]}\n\ndata: {"choices":[{"delta":{"content":"i"},"finish_reason":"stop"}]}\n\ndata: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}\n\ndata: [DONE]\n\n');
      for (final byte in payload) {
        request.response.add([byte]);
      }
      await request.response.close();
    });
    final core = SaathiCore(systemPrompt: 'synthetic');
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
    final chunks = await core.streamMessage('synthetic').toList();
    expect(chunks.map((c) => c.text).join(), 'हi');
    expect(chunks.last.metadata['totalTokens'], 6);
    expect(core.history.last.content, 'हi');
    expect(core.history.last.metadata['totalTokens'], 6);
    expect(core.isBusy, false);
  });
}
