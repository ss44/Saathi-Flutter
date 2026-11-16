import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'controller_http_test.dart' show makeStore;

void main() {
  test('FIFO dispatch waits for completion and uses the saved first answer',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <HttpRequest>[];
    final bodies = <Map<String, dynamic>>[];
    final sub = server.listen((r) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(r).join()));
      requests.add(r);
    });
    final c = ChatController(await makeStore());
    addTearDown(() async {
      c.dispose();
      await server.close(force: true);
      await sub.cancel();
    });
    await c.load();
    final connection = {
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'http://127.0.0.1:${server.port}'
    };
    await c.addConnection(connection, '');
    await c.newSession(connection, 'local', 'Prompt');
    expect(c.submit('First'), isTrue);
    expect(c.submit('Second'), isTrue);
    expect(c.submit('Third'), isTrue);
    while (requests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(requests.length, 1);
    expect(c.outbox.map((i) => i.text), ['Second', 'Third']);
    requests[0]
        .response
        .write('{"choices":[{"message":{"content":"Answer one"}}]}');
    await requests[0].response.close();
    while (requests.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(bodies[1]['messages'].map((m) => m['content']),
        ['Prompt', 'First', 'Answer one', 'Second']);
    requests[1]
        .response
        .write('{"choices":[{"message":{"content":"Answer two"}}]}');
    await requests[1].response.close();
    while (requests.length < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(bodies[2]['messages'].last['content'], 'Third');
    requests[2]
        .response
        .write('{"choices":[{"message":{"content":"Answer three"}}]}');
    await requests[2].response.close();
    while (c.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(c.current!.messages.length, 6);
  }, timeout: const Timeout(Duration(seconds: 15)));
}
