import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/ui/chat_controller.dart';

import 'agent_run_hardening_test.dart' show setup, FailingJournal;
import 'runtime_flow_test.dart' show runtimeCapabilities;

void main() {
  for (final stop in [false, true]) {
    for (final failedControl in [false, true]) {
      testWidgets(
          '${stop ? 'Stop' : 'Guide'} status observations recover polling without replay; failedControl=$failedControl',
          (t) async {
        late ChatController c;
        var unavailable = false;
        var complete = false;
        var reads = 0;
        final posts = <http.Request>[];
        final controls = <http.Request>[];
        await t.runAsync(() async {
          c = await setup(FailingJournal(), (r) async {
            expectSync(r.url.host, 'host');
            expectSync(r.headers['authorization'], 'Bearer fixture');
            expectSync(r.followRedirects, isFalse);
            if (r.url.path.endsWith('capabilities')) {
              return http.Response(jsonEncode(runtimeCapabilities), 200);
            }
            if (r.method == 'POST') {
              if (r.url.path == '/v1/runs') {
                posts.add(r);
                return http.Response(
                    '{"run_id":"original","status":"started"}', 202);
              }
              controls.add(r);
              expectSync(
                  r.url.path, '/v1/runs/original/${stop ? 'stop' : 'steer'}');
              return failedControl
                  ? http.Response('{}', 503)
                  : http.Response('{"run_id":"original","accepted":true}', 200);
            }
            expectSync(r.method, 'GET');
            expectSync(r.url.path, '/v1/runs/original');
            reads++;
            return unavailable
                ? http.Response('{}', 503)
                : http.Response(
                    jsonEncode({
                      'run_id': 'original',
                      'status': complete ? 'completed' : 'running',
                      if (complete) 'output': 'Original result',
                    }),
                    200);
          });
          await c.send('Original input');
        });
        addTearDown(c.dispose);
        Future<void> flush() async {
          for (var i = 0; i < 8; i++) {
            await t.runAsync(() => Future<void>.delayed(Duration.zero));
            await t.pump();
          }
        }

        final op = c.currentRun!;
        final session = c.current!;
        final key = op.key;
        final payload = op.payload;
        c.pauseRuns(false);
        unavailable = true;
        for (var i = 0; i < 6; i++) {
          await t.pump(const Duration(seconds: 8));
          await flush();
        }
        expect(reads, 5);
        expect(c.runObservationProblem, contains('Use Check status'));
        await t.pump(const Duration(seconds: 60));
        await flush();
        expect(reads, 5);
        if (stop) expect(c.submit('Held follower'), isTrue);
        unavailable = false;
        final controlling =
            c.controlRun(guidance: stop ? null : 'Original guidance');
        await flush();
        expect(await controlling, !failedControl);
        expect(reads, failedControl ? 6 : 7);
        expect(c.runObservationProblem, isNull);
        expect(controls, hasLength(1));
        expect(jsonDecode(controls.single.body),
            stop ? {} : {'input': 'Original guidance'});
        complete = true;
        await t.pump(const Duration(seconds: 2));
        await flush();
        expect(reads, failedControl ? 7 : 8);
        expect(op.committed, isTrue);
        expect(c.currentRun, same(op));
        expect(c.current, same(session));
        expect(session.messages.map((m) => m.content),
            ['Original input', 'Original result']);
        expect(posts, hasLength(1));
        expect(posts.single.body, payload);
        expect(posts.single.headers['Idempotency-Key'], key);
        expect(controls, hasLength(1));
        if (stop) {
          expect(c.outbox.single.text, 'Held follower');
          expect(c.queueStatus, contains('Stopped work pauses the queue'));
          expect(c.canResumeQueue, isTrue);
        }
        final settledReads = reads;
        await t.pump(const Duration(seconds: 60));
        await flush();
        expect(reads, settledReads);
        expect(posts, hasLength(1));
        expect(controls, hasLength(1));
      });
    }
  }
}
