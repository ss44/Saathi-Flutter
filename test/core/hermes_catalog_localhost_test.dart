import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_controller.dart';
import '../ui/controller_http_test.dart' show makeStore;
import '../ui/hermes_catalog_lifecycle_test.dart'
    show catalogCapabilities, enrichedCatalog;

void main() {
  test(
      'listening localhost catalog keeps metadata, deduplicates tuples, omits unauthenticated providers',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    final serving = server.listen((request) async {
      paths.add(request.uri.toString());
      expect(request.headers.value('authorization'), 'Bearer synthetic');
      request.response.headers.contentType = ContentType.json;
      request.response.write(request.uri.path.endsWith('/capabilities')
          ? catalogCapabilities
          : enrichedCatalog);
      await request.response.close();
    });
    final controller = ChatController(await makeStore());
    await controller.load();
    await controller.addConnection({
      'id': 'h',
      'name': 'Hermes',
      'type': 'hermes',
      'url': 'http://127.0.0.1:${server.port}'
    }, 'synthetic');
    final models = await controller.discover(controller.connections.single);
    expect(models.map((m) => (m.upstreamProvider, m.name)),
        [('one', 'same'), ('two', 'same')]);
    expect(paths,
        ['/v1/capabilities', '/api/model/options?include_unconfigured=false']);
    controller.dispose();
    await server.close(force: true);
    await serving.cancel();
  });
}
