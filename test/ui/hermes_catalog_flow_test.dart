import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'controller_http_test.dart' show makeStore;
import '../agent_run_hardening_test.dart' show setup;
import '../agent_run_controller_safety_test.dart' show ReconcileSecrets, answer;

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
  test(
      'provider-bearing lost admission restarts with the same immutable body and idempotency key',
      () async {
    final secrets = ReconcileSecrets();
    final keys = <String>[], bodies = <String>[];
    Future<http.Response> handler(http.Request request) async {
      if (request.method == 'POST') {
        keys.add(request.headers['Idempotency-Key']!);
        bodies.add(request.body);
        if (keys.length == 1) secrets.fail = true;
      }
      return answer(request);
    }

    final controller = await setup(secrets, handler);
    await controller.newSession(
        controller.connections.single, 'same', 'instructions',
        upstreamProvider: 'two');
    await controller.send('original');
    final original = controller.current!;
    controller.dispose();
    secrets.fail = false;
    final restored = ChatController(controller.store,
        runClientFactory: (root, key) =>
            RunClient(root, key, client: MockClient(handler)));
    await restored.load();
    restored.select(restored.sessions.singleWhere((s) => s.id == original.id));
    expect(restored.current!.upstreamProvider, 'two');
    expect(await restored.send('new work'), false);
    await restored.checkRunStatus();
    expect(keys.length, 2);
    expect(keys.toSet().length, 1);
    expect(bodies.toSet().length, 1);
    expect(jsonDecode(bodies.first)['provider'], 'two');
    expect(jsonDecode(bodies.first)['model'], 'same');
    expect(restored.current!.messages.map((m) => m.content),
        ['original', 'actual']);
    restored.dispose();
  });
  for (final runs in [false, true]) {
    testWidgets(
        'picker saves provider tuple and dispatches ${runs ? 'Runs' : 'compatibility'} after restart',
        (tester) async {
      final posts = <Map<String, dynamic>>[];
      final client = MockClient((r) async {
        if (r.method == 'POST') {
          posts.add(jsonDecode(r.body));
          return http.Response(
              runs
                  ? '{"run_id":"r1","status":"queued"}'
                  : '{"choices":[{"message":{"content":"ok"}}]}',
              runs ? 202 : 200);
        }
        if (r.url.path.endsWith('/v1/capabilities')) {
          return http.Response(
              jsonEncode({
                'features': {
                  ...(runs ? capabilities['features'] as Map : {}),
                  'model_options': true
                },
                'endpoints': {
                  ...(runs ? capabilities['endpoints'] as Map : {}),
                  'model_options': {
                    'method': 'GET',
                    'path': '/api/model/options'
                  }
                }
              }),
              200);
        }
        if (r.url.path.endsWith('/v1/runs/r1')) {
          return http.Response(
              '{"run_id":"r1","status":"completed","output":"ok"}', 200);
        }
        return http.Response(
            '{"providers":[{"slug":"one","name":"One","models":["same"]},{"slug":"two","name":"Two","models":["same"]}]}',
            200);
      });
      final store = await makeStore();
      final controller = ChatController(store,
          coreFactory: () => SaathiCore(client: client),
          runClientFactory: (root, key) =>
              RunClient(root, key, client: client));
      await controller.load();
      await controller.addConnection({
        'id': 'h',
        'name': 'Hermes',
        'type': 'hermes',
        'url': 'http://localhost:1234'
      }, 'synthetic');
      await tester
          .pumpWidget(MaterialApp(home: NewChatPage(controller: controller)));
      await tester.runAsync(() async {
        await tester.tap(find.text('Discover models'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Available models'), 180,
          scrollable: find
              .descendant(
                  of: find.byType(ListView), matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('Available models'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Two · same').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Start conversation'));
      await tester.tap(find.text('Start conversation'));
      await tester.pumpAndSettle();
      expect(controller.sessions.single.toJson()['upstreamProvider'], 'two');
      final restored = ChatController(store,
          coreFactory: () => SaathiCore(client: client),
          runClientFactory: (root, key) =>
              RunClient(root, key, client: client));
      await restored.load();
      expect(restored.current!.toJson()['upstreamProvider'], 'two');
      {
        await tester.runAsync(() => restored.send('hello'));
        expect(posts.single['provider'], 'two');
        expect(posts.single['model'], 'same');
      }
      restored.dispose();
      controller.dispose();
    });
  }
}
