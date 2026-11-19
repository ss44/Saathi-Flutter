import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'agent_runs_test.dart' show capabilities;

void main() {
  for (final admissionStatus in ['started', 'unknown']) {
    test(
        'lost first status read recovers original run without error or resend: $admissionStatus',
        () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var posts = 0, reads = 0;
      final recovered = Completer<void>();
      server.listen((r) async {
        r.response.headers.contentType = ContentType.json;
        if (r.uri.path.endsWith('capabilities')) {
          r.response.write(jsonEncode(capabilities));
        } else if (r.method == 'POST') {
          posts++;
          await r.drain<void>();
          r.response.statusCode = 202;
          r.response.write(
              jsonEncode({'run_id': 'original', 'status': admissionStatus}));
        } else if (++reads == 1) {
          r.response.statusCode = 503;
          r.response.write('{}');
        } else {
          r.response.write(
              '{"run_id":"original","status":"completed","output":"Recovered answer"}');
        }
        await r.response.close();
      });
      final c = ChatController(SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets()));
      addTearDown(() async {
        c.dispose();
        await server.close(force: true);
      });
      await c.load();
      await c.addConnection({
        'id': 'h',
        'name': 'Hermes',
        'type': 'hermes',
        'url': 'http://127.0.0.1:${server.port}'
      }, 'fixture');
      await c.newSession(c.connections.single, 'model', '');
      final errors = <String>[];
      c.addListener(() {
        if (c.error != null) errors.add(c.error!);
        if (c.current!.messages.any((m) => m.content == 'Recovered answer') &&
            !recovered.isCompleted) {
          recovered.complete();
        }
      });
      expect(await c.send('hello'), isTrue);
      expect(c.error, isNull,
          reason: 'transient read failure is not run failure');
      expect(c.pendingStatus, 'Reconnecting to check your reply');
      expect(c.showPendingThinking, isTrue,
          reason:
              'bounded read-only recovery is still active, including unknown admission status');
      await recovered.future.timeout(const Duration(seconds: 8));
      expect(c.current!.messages.map((m) => m.content),
          ['hello', 'Recovered answer']);
      expect(c.currentRun!.snapshot.state, RunState.completed);
      expect(posts, 1);
      expect(reads, 2);
      expect(errors, isEmpty);
      await c.checkRunStatus();
      expect(c.current!.messages.length, 2);
      expect(posts, 1);
    });
  }
}
