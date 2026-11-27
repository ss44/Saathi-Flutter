import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'agent_runs_test.dart' show capabilities;

class Fixture {
  late ChatController c;
  final requests = <http.Request>[];
  Future<void> init() async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    c = ChatController(store,
        runClientFactory: (root, key) =>
            RunClient(root, key, client: MockClient((r) async {
              requests.add(r);
              if (r.url.path.endsWith('capabilities')) {
                return http.Response(
                    jsonEncode({
                      'features': {
                        ...capabilities['features'] as Map,
                        'run_unknown_resolution': true
                      },
                      'endpoints': {
                        ...capabilities['endpoints'] as Map,
                        'run_unknown_resolution': {
                          'method': 'POST',
                          'path': '/v1/runs/{run_id}/resolve-unknown'
                        }
                      }
                    }),
                    200);
              }
              final id = r.url.pathSegments[2];
              return http.Response(
                  jsonEncode({
                    'run_id': id,
                    'status': 'unknown',
                    'admission_id': 'admission',
                    'execution_generation': 1
                  }),
                  200);
            })));
    await c.load();
    await c.addConnection(
        {'id': 'h', 'name': 'H', 'type': 'hermes', 'url': 'https://host'},
        'fixture');
    await add('a');
  }

  Future<void> add(String id, [String status = 'unknown']) async {
    final session = ChatSession(id: id, connectionId: 'h', model: 'model');
    c.sessions.add(session);
    c.current = session;
    final client = RunClient('https://host', 'fixture');
    final op = await client.prepare(RunLedger(c.store.secrets),
        local: id,
        input: 'pending',
        model: 'model',
        instructions: '',
        history: []);
    client.close();
    op.data.addAll({
      'run': 'run_$id',
      'authorityEpoch': c.connections.single['authorityEpoch'],
      'snapshot': {
        'run_id': 'run_$id',
        'status': status,
        'admission_id': 'admission',
        'execution_generation': 1
      }
    });
    c.runs[id] = op;
    c.notifyListeners();
  }

  Future<void> mount(WidgetTester t) =>
      t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }
}

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    if (binding.lifecycleState == AppLifecycleState.paused) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  testWidgets(
      'unchanged unknown confirmation targets original run; cancel is inert',
      (t) async {
    final f = Fixture();
    await f.init();
    await f.mount(t);
    await t.tap(find.text('Acknowledge unknown outcome'));
    await t.pumpAndSettle();
    expect(find.textContaining('Prior work may already have had side effects.'),
        findsOneWidget);
    await t.tap(find.text('Keep checking'));
    await t.pumpAndSettle();
    expect(f.requests, isEmpty);
    await t.tap(find.text('Acknowledge unknown outcome'));
    await t.pumpAndSettle();
    await t.tap(find.text('Acknowledge'));
    await t.pumpAndSettle();
    expect(f.requests.where((r) => r.method == 'POST').map((r) => r.url.path),
        ['/v1/runs/run_a/resolve-unknown']);
    await f.close(t);
  });
  testWidgets(
      'replacing original operation while dialog is open revokes consent',
      (t) async {
    final f = Fixture();
    await f.init();
    await f.mount(t);
    await t.tap(find.text('Acknowledge unknown outcome'));
    await t.pumpAndSettle();
    f.c.runs['a'] =
        RunOperation({...f.c.currentRun!.data, 'key': 'replacement'});
    await t.tap(find.text('Acknowledge'));
    await t.pumpAndSettle();
    expect(f.requests, isEmpty);
    await f.close(t);
  });
  testWidgets('remount resumes polling only in resumed lifecycle', (t) async {
    final f = Fixture();
    await f.init();
    await f.add('b', 'running');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await f.mount(t);
    await t.pumpWidget(const SizedBox());
    await f.mount(t);
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(f.requests.where((r) => r.url.path == '/v1/runs/run_b'), isNotEmpty);
    f.requests.clear();
    f.c.currentRun!.data['snapshot'] = {'run_id': 'run_b', 'status': 'running'};
    await t.pumpWidget(const SizedBox());
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await f.mount(t);
    await t.pump(const Duration(seconds: 4));
    await t.pump();
    expect(f.requests, isEmpty);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump(const Duration(seconds: 2));
    await t.pump();
    expect(f.requests, isNotEmpty);
    await f.close(t);
  });
  testWidgets(
      'playful pending presentation keeps truthful native status between polls',
      (t) async {
    final f = Fixture();
    await f.init();
    await f.mount(t);
    for (final status in [
      'queued',
      'running',
      'unknown',
      'completed',
      'failed',
      'waiting_for_approval',
      'stopping',
      'unrecognized'
    ]) {
      f.c.currentRun!.data['snapshot'] = {'run_id': 'run_a', 'status': status};
      for (final busy in [false, true]) {
        f.c.busy = busy;
        f.c.notifyListeners();
        await t.pump();
        expect(
            find.byType(BusyThinking),
            status == 'queued' || status == 'running'
                ? findsOneWidget
                : findsNothing,
            reason: '$status busy=$busy');
        expect(find.textContaining('Run:'), findsNothing);
        if (status == 'queued' || status == 'running') {
          final label = status == 'queued'
              ? 'Waiting for its turn'
              : 'Working on your reply';
          expect(f.c.pendingStatus, label);
          if (defaultTargetPlatform == TargetPlatform.android) {
            expect(find.byKey(const Key('thinking-quip')), findsOneWidget);
            expect(
                find.ancestor(
                    of: find.byKey(const Key('thinking-quip')),
                    matching: find.byType(BusyThinking)),
                findsOneWidget);
            for (final phase in [
              'Sending your message',
              'Waiting for its turn',
              'Working on your reply',
            ]) {
              expect(find.text(phase), findsNothing);
            }
          } else {
            expect(find.text(label), findsWidgets);
          }
        } else {
          expect(find.byKey(const Key('thinking-quip')), findsNothing);
        }
        if (status == 'completed') {
          expect(f.c.pendingStatus, 'Reply received');
          expect(find.text('Reply received'), findsOneWidget);
        }
        await t.pump(const Duration(milliseconds: 100));
      }
    }
    f.c.busy = false;
    await f.close(t);
  },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.linux,
      }));
  testWidgets(
      'unknown confirmation cannot acknowledge a different selected chat',
      (t) async {
    final f = Fixture();
    await f.init();
    await f.mount(t);
    await t.tap(find.text('Acknowledge unknown outcome'));
    await t.pumpAndSettle();
    await f.add('b');
    await t.pump();
    await t.tap(find.text('Acknowledge'));
    await t.pumpAndSettle();
    expect(f.requests, isEmpty);
    await f.close(t);
  });
}
