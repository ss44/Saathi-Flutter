import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'agent_run_hardening_test.dart' show FailingJournal, setup;
import 'agent_runs_test.dart' show capabilities;

void main() {
  for (final explicit in [false, true]) {
    test(
        'authoritative completion retires unknown-only queue barrier; explicit=$explicit',
        () async {
      var status = 'unknown';
      var posts = 0;
      final c = await setup(FailingJournal(), (r) async {
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          return http.Response(
              jsonEncode({'run_id': 'r${++posts}', 'status': 'started'}), 202);
        }
        return http.Response(
            jsonEncode({
              'run_id': r.url.path.split('/').last,
              'status': status,
              if (status == 'completed') 'output': 'Recovered exact reply',
            }),
            200);
      });
      addTearDown(c.dispose);
      expect(c.submit('first'), isTrue);
      expect(c.submit('follower'), isTrue);
      final deadline = Stopwatch()..start();
      while ((posts == 0 || c.busy) &&
          deadline.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(c.queueStatus, isNotNull);
      expect(posts, 1);
      if (explicit) c.pauseQueue('Paused by you');
      status = 'completed';
      await c.checkRunStatus();
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(posts, explicit ? 1 : 2,
          reason:
              'The exact original terminal receipt resolves uncertainty, not a user pause');
      expect(
          c.current!.messages.where((m) => m.content == 'first'), hasLength(1));
      if (explicit) expect(c.queueStatus, 'Paused by you');
    });
  }
}
