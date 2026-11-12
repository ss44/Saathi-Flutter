import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

Future<SaathiStore> makeStore() async {
  SharedPreferences.setMockInitialValues({});
  return SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets());
}

void main() {
  test(
      'real localhost requests keep transcript and endpoint bound to each session',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final paths = <String>[];
    final serving = server.listen((request) async {
      paths.add(request.uri.path);
      if (request.method == 'POST') {
        bodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
        request.response.write(
            '{"choices":[{"message":{"content":"Hello from localhost"}}]}');
      } else {
        request.response.write('{"data":[{"id":"local"}]}');
      }
      await request.response.close();
    });
    final store = await makeStore();
    final controller = ChatController(store);
    await controller.load();
    final first = {
      'id': 'a',
      'name': 'A',
      'url': 'http://127.0.0.1:${server.port}',
      'type': 'openai'
    };
    final second = {
      'id': 'b',
      'name': 'B',
      'url': 'http://127.0.0.1:1',
      'type': 'openai'
    };
    await controller.addConnection(first, '');
    await controller.addConnection(second, '');
    expect((await controller.discover(first)).single.name, 'local');
    await controller.newSession(first, 'local', 'Be concise');
    expect(await controller.send('First'), isTrue);
    final saved = controller.current!;
    await controller.newSession(second, 'other', '');
    controller.select(saved);
    expect(await controller.send('Second'), isTrue);
    expect(bodies.last['messages'].map((m) => m['content']).toList(),
        ['Be concise', 'First', 'Hello from localhost', 'Second']);
    expect(
        paths, ['/v1/models', '/v1/chat/completions', '/v1/chat/completions']);
    final reloaded = ChatController(store);
    await reloaded.load();
    expect(reloaded.sessions.first.messages.length, 4);
    expect(reloaded.sessions.last.messages, isEmpty);
    controller.dispose();
    reloaded.dispose();
    await server.close(force: true);
    await serving.cancel();
  });
}
