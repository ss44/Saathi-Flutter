import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/core/saathi_core.dart';

void main() {
  test(
      'changing instance endpoint or identity clears old history and discovered models',
      () {
    final core = SaathiCore();
    addTearDown(core.close);
    core.addProvider(const ProviderConfig(
        id: 'a',
        name: 'First',
        type: ProviderType.openai,
        baseUrl: 'https://one.example'));
    core.registerModel(const ModelInfo(providerId: 'a', name: 'model'));
    core.restoreHistory(
        [ChatMessage(role: 'user', content: 'synthetic old context')]);
    core.addProvider(const ProviderConfig(
        id: 'a',
        name: 'Renamed',
        type: ProviderType.openai,
        baseUrl: 'https://one.example'));
    expect(core.history.length, 1);
    expect(core.models.length, 1);
    core.addProvider(const ProviderConfig(
        id: 'a',
        name: 'Renamed',
        type: ProviderType.openai,
        baseUrl: 'https://two.example'));
    expect(core.history, isEmpty);
    expect(core.models, isEmpty);
    expect(core.currentModel, isNull);
  });

  test(
      'core rejects cleartext nonloopback and query/credential/fragment URL roots',
      () async {
    final core = SaathiCore();
    addTearDown(core.close);
    for (final root in [
      'http://example.com',
      'https://user:secret@example.com',
      'https://example.com?key=secret',
      'https://example.com/#secret'
    ]) {
      expect(
          () => core.addProvider(ProviderConfig(
              id: 'a',
              name: 'Unsafe',
              type: ProviderType.openai,
              baseUrl: root)),
          throwsArgumentError);
    }
    expect(core.providers, isEmpty);
  });

  test(
      'bounded HTTP reads redact errors and injected client remains caller owned',
      () async {
    var mode = 'large';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (mode == 'slow') {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(mode == 'large'
          ? jsonEncode({'data': [], 'padding': 'x' * 1024})
          : '{"data":[]}');
      await request.response.close();
    });
    final client = http.Client();
    final core = SaathiCore(
        client: client,
        requestTimeout: const Duration(seconds: 2),
        maxResponseBytes: 100);
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    final config = ProviderConfig(
        id: 'a',
        name: 'Local',
        type: ProviderType.openai,
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'synthetic-secret');
    core.addProvider(config);
    await expectLater(
        core.discoverModels('a'),
        throwsA(isA<ProviderException>()
            .having((e) => e.message, 'bounded', contains('size'))));
    mode = 'slow';
    // Keep the size-limit assertion independent from a deliberately short deadline.
    // Otherwise slow CI startup can time out before it even reaches the large body.
    final timeoutCore = SaathiCore(
        client: client, requestTimeout: const Duration(milliseconds: 50));
    timeoutCore.addProvider(config);
    await expectLater(
        timeoutCore.discoverModels('a'),
        throwsA(isA<ProviderException>()
            .having((e) => e.toString(), 'timeout', contains('timed out'))
            .having((e) => e.toString(), 'redacted',
                isNot(contains('synthetic-secret')))));
    timeoutCore.close();
    core.close();
    mode = 'ok';
    expect((await client.get(Uri.parse('${config.baseUrl}/probe'))).statusCode,
        200);
  });

  test(
      'active conversation rejects rerouting and reset cannot resurrect an answer',
      () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      arrived.complete();
      await release.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
          '{"choices":[{"message":{"content":"synthetic"},"finish_reason":"stop"}]}');
      await request.response.close();
    });
    final core = SaathiCore();
    addTearDown(() async {
      core.close();
      await server.close(force: true);
    });
    final config = ProviderConfig(
        id: 'a',
        name: 'Local',
        type: ProviderType.openai,
        baseUrl: 'http://127.0.0.1:${server.port}');
    core.addProvider(config);
    core.registerModel(const ModelInfo(providerId: 'a', name: 'one'));
    core.registerModel(const ModelInfo(providerId: 'a', name: 'two'));
    final pending = core.sendMessage('synthetic');
    await arrived.future;
    expect(() => core.selectModel('a|two'), throwsStateError);
    expect(() => core.addProvider(config), throwsStateError);
    expect(() => core.removeProvider('a'), throwsStateError);
    await expectLater(core.sendMessage('duplicate'), throwsStateError);
    core.clearHistory();
    release.complete();
    await pending;
    expect(core.history, isEmpty);
    expect(core.isBusy, false);
  });
}
