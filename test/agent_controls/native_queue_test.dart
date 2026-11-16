import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import '../agent_run_hardening_test.dart' show setup, FailingJournal;
import '../agent_run_queue_test.dart' show settle;
import '../agent_runs_test.dart' show capabilities;

void main() {
  for (final paused in [false, true]) {
    test('control refresh completion preserves queue pause=$paused', () async {
      var posts = 0;
      var complete = false;
      final c = await setup(FailingJournal(), (r) async {
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          posts++;
          return http.Response(
              jsonEncode({'run_id': 'r$posts', 'status': 'started'}), 202);
        }
        return http.Response(
            jsonEncode({
              'run_id': r.url.path.split('/').last,
              'status': complete ? 'completed' : 'running',
              if (complete) 'output': 'Actual terminal answer'
            }),
            200);
      });
      addTearDown(c.dispose);
      c.submit('first');
      c.submit('second');
      await settle();
      expect(posts, 1);
      if (paused) {
        c.setQueueBackground(true);
        c.setQueueBackground(false);
      }
      complete = true;
      final controls = await c.openRunControls(isOwnerCurrent: () => true);
      addTearDown(() => controls?.dispose());
      await settle();
      expect(
          c.current!.messages.any((m) => m.content == 'Actual terminal answer'),
          isTrue);
      expect(posts, paused ? 1 : 2);
      if (paused) expect(c.canResumeQueue, isTrue);
    });
  }
}
