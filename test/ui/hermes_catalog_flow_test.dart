import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/chat_home.dart';
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
  testWidgets(
      'provider-bearing lost admission retains exact noncanonical journal without resubmission after restart',
      (tester) async {
    final secrets = ReconcileSecrets();
    final requests = <http.Request>[];
    final keys = <String>[], bodies = <String>[];
    Future<http.Response> handler(http.Request request) async {
      requests.add(request);
      if (request.method == 'POST') {
        keys.add(request.headers['Idempotency-Key']!);
        bodies.add(request.body);
        secrets.fail = true; // The server ACK cannot be durably recorded.
      }
      return answer(request);
    }

    late ChatController controller;
    late SaathiStore store;
    late ChatSession original;
    late String payload, journalKey, rawJournal;
    late Map<String, dynamic> operation;
    late Map<String, dynamic> originalSource;
    await tester.runAsync(() async {
      controller = await setup(secrets, handler);
      store = controller.store;
      controller.current!.messages.add(ChatMessage(
          role: 'user', content: 'Nonempty private history from another chat'));
      expect(controller.current!.messages, isNotEmpty);
      await controller.persist();
      await controller.newSession(
          controller.connections.single, 'same', 'instructions',
          upstreamProvider: 'two');
      original = controller.current!;
      originalSource = Map<String, dynamic>.from(controller.connections.single);
      // A restored prepared operation can contain valid noncanonical JSON.
      // Seed that exact record before the controller/ledger owns its identity.
      final preparer = RunClient('https://host', 'fixture');
      final prepared = await preparer.prepare(RunLedger(MemorySecrets()),
          local: original.id,
          input: 'original',
          model: 'same',
          provider: 'two',
          instructions: 'instructions',
          authorityEpoch: originalSource['authorityEpoch'] as String,
          history: []);
      preparer.close();
      payload = const JsonEncoder.withIndent('  ')
          .convert(jsonDecode(prepared.payload));
      expect(payload, isNot(jsonEncode(jsonDecode(payload))));
      journalKey = 'run.v1.${original.id}';
      await secrets.write(
          journalKey, jsonEncode({...prepared.data, 'payload': payload}));
      controller.dispose();
      controller = ChatController(store,
          runClientFactory: (root, key) =>
              RunClient(root, key, client: MockClient(handler)));
      await controller.load();
      controller
          .select(controller.sessions.singleWhere((s) => s.id == original.id));
      expect(controller.currentRun!.data['attempted'], isNot(true));
      await controller
          .checkRunStatus(); // Explicit first send, not uncertain replay.
      expect(keys, [prepared.key]);
      expect(bodies, [payload]);
      expect(jsonDecode(payload)['provider'], 'two');
      expect(jsonDecode(payload)['model'], 'same');
      expect(payload, isNot(contains('Nonempty private history')));
      rawJournal = (await secrets.read(journalKey))!;
      operation = Map<String, dynamic>.from(jsonDecode(rawJournal) as Map);
      expect(operation['attempted'], isTrue);
      expect(operation['run'], isNull);
      expect(operation['payload'], payload);
      expect(operation['key'], keys.single);
      expect(operation['local'], original.id);
      expect(operation['session'], prepared.sessionId);
      expect(operation['scope'], prepared.data['scope']);
      expect(operation['created'], prepared.data['created']);
      expect(operation['capturedInstructions'], 'instructions');
      expect(operation['authorityEpoch'], originalSource['authorityEpoch']);
      expect(operation['origin'], originalSource['url']);
      controller.dispose();
      secrets.fail = false;
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    for (var restart = 0; restart < 2; restart++) {
      await tester.runAsync(() async {
        controller = ChatController(store,
            runClientFactory: (root, key) =>
                RunClient(root, key, client: MockClient(handler)));
        await controller.load();
        controller.select(
            controller.sessions.singleWhere((s) => s.id == original.id));
        expect(controller.current!.upstreamProvider, 'two');
        expect(controller.current!.model, 'same');
        expect(controller.current!.systemPrompt, 'instructions');
        expect(controller.connections.single, originalSource);
        expect(controller.currentRun!.data, operation);
        expect(await controller.send('new work'), isFalse);
        for (var check = 0; check < 4; check++) {
          await controller.checkRunStatus();
        }
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester
          .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(seconds: 30));
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => controller.checkRunStatus());
      }
      await tester.pump();
      await tester.runAsync(() async {
        expect(await secrets.read(journalKey), rawJournal);
      });
      expect(controller.currentRun!.data, operation);
      expect(controller.currentRun!.runId, isNull);
      expect(controller.currentRun!.committed, isFalse);
      expect(controller.runPending, isTrue);
      expect(controller.showPendingThinking, isFalse);
      expect(controller.current!.messages, isEmpty);
      expect(controller.pendingText, 'original');
      expect(controller.runObservationProblem, contains('Tap Refresh'));
      expect(find.textContaining('Tap Refresh'), findsOneWidget);
      expect(find.byType(BusyThinking), findsNothing);
      expect(find.text('actual'), findsNothing);
      expect(requests.where((r) => r.url.path.startsWith('/v1/runs/')), isEmpty,
          reason: 'No invented run ID or status GET');
      expect(keys, [operation['key']]);
      expect(bodies, [payload]);
      expect(requests.every((r) => r.url.host == 'host'), isTrue);
      expect(
          requests.every((r) => r.headers['authorization'] == 'Bearer fixture'),
          isTrue);
      final preferences = jsonEncode({
        for (final key in store.preferences.getKeys())
          key: store.preferences.get(key)
      });
      expect(preferences, isNot(contains('fixture')));
      expect(preferences, isNot(contains('"payload"')));
      expect(preferences, isNot(contains('"original"')));
      expect(preferences, isNot(contains(operation['key'] as String)));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pump();
    }
  });
  for (final runs in [false, true]) {
    testWidgets(
        'picker restores provider tuple after restart: ${runs ? 'Runs dispatch' : 'platform compatibility policy'}',
        (tester) async {
      final posts = <Map<String, dynamic>>[];
      final requests = <http.Request>[];
      final client = MockClient((r) async {
        requests.add(r);
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
      expect(controller.sessions.single.model, 'same');
      final originalId = controller.sessions.single.id;
      final originalSource =
          Map<String, dynamic>.from(controller.connections.single);
      expect(posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await store.preferences.reload();
      final restored = ChatController(store,
          coreFactory: () => SaathiCore(client: client),
          runClientFactory: (root, key) =>
              RunClient(root, key, client: client));
      await restored.load();
      expect(restored.current!.id, originalId);
      expect(restored.connections.single, originalSource);
      expect(restored.current!.toJson()['upstreamProvider'], 'two');
      expect(restored.current!.model, 'same');
      final sent = await tester.runAsync(() => restored.send('hello'));
      if (!runs && defaultTargetPlatform == TargetPlatform.android) {
        expect(sent, isFalse);
        expect(posts, isEmpty);
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
        expect(
            restored.error,
            'This Hermes connection needs durable Runs for Android replies. '
            'Enable Runs on the original server, then try again. Nothing was sent.');
        expect(restored.currentRun, isNull);
        expect(restored.runPending, isFalse);
        expect(restored.current!.messages, isEmpty);
        await tester.runAsync(() async {
          expect(await store.secrets.read('run.v1.$originalId'), isNull);
        });
      } else {
        expect(sent, isTrue);
        expect(posts.single['provider'], 'two');
        expect(posts.single['model'], 'same');
        expect(requests.where((r) => r.method == 'POST').single.url.path,
            runs ? '/v1/runs' : '/v1/chat/completions');
      }
      expect(restored.current!.upstreamProvider, 'two');
      expect(restored.current!.model, 'same');
      expect(restored.current!.id, originalId);
      expect(restored.connections.single, originalSource);
      expect(requests.every((r) => r.url.host == 'localhost'), isTrue);
      restored.dispose();
    },
        variant: TargetPlatformVariant(
            {TargetPlatform.android, TargetPlatform.linux}));
  }
}
