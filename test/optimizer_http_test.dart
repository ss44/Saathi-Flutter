import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/prompt_optimizer.dart';
import 'prompt_optimizer_acceptance_test.dart' as fixture;

void main() {
  test(
      'real localhost catalog and draft-only HTTP rewrite without agent endpoints',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    final payloads = <Map>[];
    server.listen((request) async {
      paths.add('${request.method} ${request.uri.path}');
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        request.response.write(jsonEncode({
          'data': [
            {'id': 'verified'}
          ]
        }));
      } else {
        payloads
            .add(jsonDecode(await utf8.decoder.bind(request).join()) as Map);
        request.response.write(fixture.response('Rewritten'));
      }
      await request.response.close();
    });
    final core = SaathiCore();
    final config = ProviderConfig(
        id: 'local',
        name: 'Local fixture',
        type: ProviderType.openai,
        baseUrl: 'http://127.0.0.1:${server.port}');
    core.addProvider(config);
    final catalog = await core.discoverModels('local');
    expect(catalog.single.name, 'verified');
    expect(
        await rewritePrompt(
            core, config, catalog.single.name, 'Only this draft'),
        'Rewritten');
    expect(paths, ['GET /v1/models', 'POST /v1/chat/completions']);
    expect(payloads.single['messages'], hasLength(2));
    expect(payloads.single.containsKey('tools'), isFalse);
    expect(payloads.single['model'], 'verified');
    core.close();
    await server.close(force: true);
  });
}
