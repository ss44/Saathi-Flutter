import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'agent_run_hardening_test.dart' show setup, FailingJournal;
import 'agent_run_queue_test.dart' show settle;
import 'agent_runs_test.dart' show capabilities;

import 'package:saathi/core/saathi_core.dart';
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/ui/chat_controller.dart';

class InitialWriteGate extends FailingJournal {
  final entered = Completer<void>();
  final release = Completer<void>();
  String? prepared;
  @override
  Future<void> write(String id, String value) async {
    if (id.startsWith('run.v1.') && prepared == null) {
      prepared = value;
      entered.complete();
      await release.future;
    }
    await super.write(id, value);
  }
}

void main() {
  for (final boundary in ['discovery', 'status']) {
    test('pause resume revokes captured $boundary permission', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var posts = 0;
      final c = await setup(FailingJournal(), (r) async {
        if ((boundary == 'discovery' && r.url.path.endsWith('capabilities')) ||
            (boundary == 'status' && r.url.path == '/v1/runs/r')) {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          posts++;
          return http.Response('{"run_id":"r","status":"started"}', 202);
        }
        return http.Response(
            '{"run_id":"r","status":"completed","output":"stale"}', 200);
      });
      addTearDown(c.dispose);
      final sending = c.send('first');
      await entered.future;
      c.pauseRuns(true);
      c.pauseRuns(false);
      release.complete();
      await sending;
      expect(posts, boundary == 'discovery' ? 0 : 1);
      expect(c.current!.messages, isEmpty);
      if (boundary == 'status') {
        expect(c.currentRun!.snapshot.terminal, false);
        expect(c.currentRun!.committed, false);
      }
    });
  }
  for (final body in ['', '<html>not found</html>']) {
    test('discovery 404 $body performs actual legacy chat fallback', () async {
      final initial =
          await setup(FailingJournal(), (r) async => http.Response('{}', 500));
      var chats = 0;
      var discoveries = 0;
      final c = ChatController(initial.store,
          runClientFactory: (root, key) =>
              RunClient(root, key, client: MockClient((r) async {
                expect(r.method, 'GET');
                expect(r.url.path, '/v1/capabilities');
                discoveries++;
                return http.Response(body, 404);
              })),
          coreFactory: () => SaathiCore(client: MockClient((r) async {
                expect(r.url.path, '/v1/chat/completions');
                chats++;
                return http.Response(
                    jsonEncode({
                      'choices': [
                        {
                          'message': {'content': 'legacy actual'}
                        }
                      ]
                    }),
                    200);
              })));
      initial.dispose();
      await c.load();
      addTearDown(c.dispose);
      await c.send('first');
      expect(discoveries, 1);
      expect(chats, 1);
      expect(c.current!.messages.map((m) => m.content),
          ['first', 'legacy actual']);
      expect(c.runs, isEmpty);
    });
  }
  for (final kind in ['background', 'switch']) {
    test(
        '$kind during initial journal retains exact never-dispatched operation',
        () async {
      final secrets = InitialWriteGate();
      final bodies = <String>[];
      final keys = <String>[];
      var requests = 0;
      final c = await setup(secrets, (r) async {
        requests++;
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          bodies.add(r.body);
          keys.add(r.headers['Idempotency-Key']!);
          return http.Response('{"run_id":"r","status":"started"}', 202);
        }
        return http.Response(
            '{"run_id":"r","status":"completed","output":"actual"}', 200);
      });
      addTearDown(c.dispose);
      final original = c.current!;
      c.submit('first');
      c.submit('follower');
      await secrets.entered.future;
      if (kind == 'background') {
        c.setQueueBackground(true);
      } else {
        final other =
            ChatSession(id: 'other', connectionId: 'h', model: 'model');
        c.sessions.add(other);
        c.select(other);
      }
      secrets.release.complete();
      await settle();
      expect(bodies, isEmpty);
      expect(requests, 1); // Only discovery before the prepared write.
      final durable = (await RunLedger(secrets).load(original.id))!;
      expect(c.runs[original.id]?.key, durable.key);
      expect(c.runs[original.id]!.data['attempted'], isNot(true));
      expect(c.uncertainInput, isNull);
      if (kind == 'background') c.setQueueBackground(false);
      c.select(original);
      await settle();
      expect(bodies, isEmpty);
      expect(requests, 1); // Resume/select cannot silently reconnect.
      expect(c.pendingText, 'first');
      expect(c.outbox.map((e) => e.text), ['follower']);
      await c.checkRunStatus();
      await settle();
      expect(keys, [durable.key]);
      expect(bodies, [durable.payload]);
      expect(c.current!.messages.map((m) => m.content), ['first', 'actual']);
      expect(c.canResumeQueue, true);
      c.resumeQueue();
      await settle();
      expect(bodies.length, 2);
      expect(c.current!.messages.map((m) => m.content),
          ['first', 'actual', 'follower', 'actual']);
    });
  }
  for (final output in ['missing', 'wrong type', 'empty']) {
    test('completed GET requires explicit typed output: $output', () async {
      var posts = 0;
      final c = await setup(FailingJournal(), (r) async {
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          posts++;
          return http.Response('{"run_id":"r","status":"started"}', 202);
        }
        return http.Response(
            jsonEncode({
              'run_id': 'r',
              'status': 'completed',
              if (output != 'missing') 'output': output == 'empty' ? '' : 12,
            }),
            200);
      });
      addTearDown(c.dispose);
      c.submit('first');
      if (output != 'empty') c.submit('follower');
      await settle();
      expect(posts, 1);
      expect(c.runPending, output != 'empty');
      expect(c.current!.messages.length, output == 'empty' ? 2 : 0);
      if (output != 'empty') {
        expect(c.currentRun!.committed, false);
        expect(c.outbox.map((e) => e.text), ['follower']);
      }
    });
  }
  test('completed admission cannot override authoritative running GET',
      () async {
    var posts = 0;
    final c = await setup(FailingJournal(), (r) async {
      if (r.url.path.endsWith('capabilities')) {
        return http.Response(jsonEncode(capabilities), 200);
      }
      if (r.method == 'POST') {
        posts++;
        return http.Response(
            '{"run_id":"r","status":"completed","output":"untrusted"}', 202);
      }
      return http.Response('{"run_id":"r","status":"running"}', 200);
    });
    addTearDown(c.dispose);
    c.submit('first');
    c.submit('follower');
    await settle();
    expect(posts, 1);
    expect(c.runPending, true);
    expect(c.current!.messages, isEmpty);
    expect(c.outbox.map((e) => e.text), ['follower']);
    expect(c.currentRun!.snapshot.status, 'running');
  });
}
