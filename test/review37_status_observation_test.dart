import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'agent_runs_test.dart' show capabilities;

void main() {
  for (final invalid in ['missing', 'unrecognized']) {
    testWidgets('independent: $invalid status cannot replace original journal',
        (t) async {
      late ChatController c;
      var broken = false;
      var posts = 0;
      await t.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        c = ChatController(
            SaathiStore(
                preferences: await SharedPreferences.getInstance(),
                secrets: MemorySecrets()),
            runClientFactory: (root, key) =>
                RunClient(root, key, client: MockClient((r) async {
                  if (r.url.path.endsWith('capabilities')) {
                    return http.Response(jsonEncode(capabilities), 200);
                  }
                  if (r.method == 'POST') {
                    posts++;
                    return http.Response(
                        '{"run_id":"original","status":"running"}', 202);
                  }
                  return http.Response(
                      jsonEncode({
                        'run_id': 'original',
                        if (!broken) 'status': 'running',
                        if (broken && invalid == 'unrecognized')
                          'status': 'not_a_run_state',
                      }),
                      200);
                })));
        await c.load();
        await c.addConnection({
          'id': 'original',
          'name': 'Original',
          'type': 'hermes',
          'url': 'https://original.example'
        }, 'fixture');
        await c.newSession(c.connections.single, 'model', '');
        await c.send('input');
      });
      final original = jsonDecode(jsonEncode(c.currentRun!.data));
      final key = 'run.v1.${c.current!.id}';
      final before = await t.runAsync(() => c.store.secrets.read(key));
      broken = true;
      await t.runAsync(() => c.checkRunStatus());
      final after = await t.runAsync(() => c.store.secrets.read(key));
      c.dispose();
      expect(posts, 1);
      expect(c.current!.messages, isEmpty);
      expect(after, before, reason: 'Keep exact last valid journal bytes');
      expect(c.currentRun!.data, original,
          reason:
              'Malformed or unrecognized status is not an authoritative replacement');
    });
  }
  testWidgets('independent: unrecognized observations stop automatic requests',
      (t) async {
    late ChatController c;
    var broken = false;
    var reads = 0, posts = 0;
    await t.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      c = ChatController(
          SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: MemorySecrets()),
          runClientFactory: (root, key) =>
              RunClient(root, key, client: MockClient((r) async {
                if (r.url.path.endsWith('capabilities')) {
                  return http.Response(jsonEncode(capabilities), 200);
                }
                if (r.method == 'POST') {
                  posts++;
                  return http.Response(
                      '{"run_id":"original","status":"running"}', 202);
                }
                reads++;
                return http.Response(
                    jsonEncode({
                      'run_id': 'original',
                      'status': broken ? 'not_a_run_state' : 'running'
                    }),
                    200);
              })));
      await c.load();
      await c.addConnection({
        'id': 'original',
        'name': 'Original',
        'type': 'hermes',
        'url': 'https://original.example'
      }, 'fixture');
      await c.newSession(c.connections.single, 'model', '');
      await c.send('input');
    });
    Future<void> flush() async {
      for (var i = 0; i < 8; i++) {
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
        await t.pump();
      }
    }

    broken = true;
    c.pauseRuns(false);
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(seconds: 8));
      await flush();
    }
    final exhaustedReads = reads;
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(seconds: 8));
      await flush();
    }
    final finalReads = reads;
    c.dispose();
    expect(posts, 1);
    expect(finalReads, exhaustedReads,
        reason:
            'No indefinite requests on observations that cannot establish ongoing work');
  });
}
