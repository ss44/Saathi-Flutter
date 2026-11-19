import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/ui/chat_controller.dart';

import 'agent_run_hardening_test.dart' show setup, FailingJournal;
import 'runtime_flow_test.dart' show runtimeCapabilities;

void main() {
  for (final resolutionCode in [null, 200, 409, 503]) {
    for (final observed in ['running', 'completed']) {
      testWidgets(
          'unknown resolution $resolutionCode recovers observed $observed',
          (t) async {
        late ChatController c;
        var status = 'unknown';
        var unavailable = false;
        var reads = 0;
        final posts = <http.Request>[];
        final resolutions = <http.Request>[];
        await t.runAsync(() async {
          c = await setup(FailingJournal(), (r) async {
            expectSync(r.url.host, 'host');
            expectSync(r.headers['authorization'], 'Bearer fixture');
            expectSync(r.followRedirects, isFalse);
            if (r.url.path.endsWith('capabilities')) {
              return http.Response(
                  jsonEncode({
                    'features': {
                      ...runtimeCapabilities['features'] as Map,
                      'run_unknown_resolution': true,
                    },
                    'endpoints': {
                      ...runtimeCapabilities['endpoints'] as Map,
                      'run_unknown_resolution': {
                        'method': 'POST',
                        'path': '/v1/runs/{run_id}/resolve-unknown',
                      },
                    },
                  }),
                  200);
            }
            if (r.method == 'POST') {
              if (r.url.path == '/v1/runs') {
                posts.add(r);
                return http.Response(
                    '{"run_id":"original","status":"started"}', 202);
              }
              expectSync(resolutionCode, isNotNull);
              expectSync(r.url.path, '/v1/runs/original/resolve-unknown');
              resolutions.add(r);
              status = observed;
              return http.Response('{}', resolutionCode!);
            }
            expectSync(r.method, 'GET');
            expectSync(r.url.path, '/v1/runs/original');
            reads++;
            return unavailable
                ? http.Response('{}', 503)
                : http.Response(
                    jsonEncode({
                      'run_id': 'original',
                      'status': status,
                      'admission_id': 'admission',
                      'execution_generation': 3,
                      if (status == 'completed') 'output': 'Original result',
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
        unavailable = true;
        for (var i = 0; i < 4; i++) {
          final check = c.checkRunStatus();
          await flush();
          await check;
        }
        expect(reads, 5);
        expect(c.runObservationProblem, contains('Use Check status'));
        unavailable = false;
        status = resolutionCode == null ? observed : 'unknown';
        // If the pending action is stale, its authoritative preflight must not
        // send a resolution POST. Conflicts and ACKs require their own fresh GET.
        final resolving = c.checkRunStatus(acknowledgeUnknown: true);
        await flush();
        await resolving;
        final refreshed = resolutionCode == 200 || resolutionCode == 409;
        expect(reads, refreshed ? 7 : 6);
        expect(resolutions, hasLength(resolutionCode == null ? 0 : 1));
        if (resolutions.isNotEmpty) {
          expect(jsonDecode(resolutions.single.body), {
            'admission_id': 'admission',
            'execution_generation': 3,
          });
        }
        status = 'completed';
        await t.pump(const Duration(seconds: 2));
        await flush();
        final needsPoll = observed == 'running' || resolutionCode == 503;
        expect(reads, (refreshed ? 7 : 6) + (needsPoll ? 1 : 0));
        expect(op.committed, isTrue);
        expect(c.currentRun, same(op));
        expect(c.current!.messages.map((m) => m.content),
            ['Original input', 'Original result']);
        expect(posts, hasLength(1));
        expect(posts.single.body, op.payload);
        expect(posts.single.headers['Idempotency-Key'], op.key);
        final settledReads = reads;
        await t.pump(const Duration(seconds: 60));
        await flush();
        expect(reads, settledReads);
        expect(resolutions, hasLength(resolutionCode == null ? 0 : 1));
      });
    }
  }
}
