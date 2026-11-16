import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

const capabilities = {
  'features': {
    'run_submission': true,
    'run_status': true,
    'runs_idempotency': {'supported': true}
  },
  'endpoints': {
    'runs': {'method': 'POST', 'path': '/v1/runs'},
    'run_status': {'method': 'GET', 'path': '/v1/runs/{run_id}'}
  }
};
void main() {
  test('Hermes admission is polled and committed exactly once to its own chat',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final paths = <String>[];
    final bodies = <Map>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      paths.add('${r.method} ${r.uri.path}');
      r.response.headers.contentType = ContentType.json;
      if (r.uri.path.endsWith('capabilities')) {
        r.response.write(jsonEncode(capabilities));
      } else if (r.method == 'POST') {
        expect(r.headers.value('Idempotency-Key'), isNotEmpty);
        bodies.add(jsonDecode(await utf8.decoder.bind(r).join()) as Map);
        r.response.statusCode = 202;
        r.response.write('{"run_id":"run_1","status":"started"}');
      } else {
        r.response
            .write('{"run_id":"run_1","status":"completed","output":"answer"}');
      }
      await r.response.close();
    });
    final c = ChatController(store);
    await c.load();
    final connection = {
      'id': 'h',
      'name': 'Hermes',
      'type': 'hermes',
      'url': 'http://127.0.0.1:${server.port}'
    };
    await c.addConnection(connection, 'fixture');
    await c.newSession(connection, 'model', 'Be brief');
    expect(await c.send('hello'), true);
    expect(
        paths, ['GET /v1/capabilities', 'POST /v1/runs', 'GET /v1/runs/run_1']);
    expect(c.current!.messages.map((m) => m.content), ['hello', 'answer']);
    expect(bodies.single['session_id'], startsWith('saathi_'));
    expect(c.current!.messages.length, 2);
    c.dispose();
    await server.close(force: true);
  });
}
