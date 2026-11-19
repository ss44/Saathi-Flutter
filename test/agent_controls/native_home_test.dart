import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import '../agent_runs_test.dart' show capabilities;

class NativeControlsFixture {
  NativeControlsFixture({this.clarify = false});
  final bool clarify;
  final requests = <http.Request>[];
  bool pending = true;
  int responseCode = 200;
  bool legacyReceipt = false;
  bool approvalSupported = true;
  int generation = 3;
  String approvalPath = '/v1/runs/{run_id}/approval';
  Completer<void>? holdGet;
  late ChatController c;
  Map<String, dynamic> snapshot() => {
        'run_id': 'run_a',
        'admission_id': 'adm_a',
        'execution_generation': generation,
        'status': clarify ? 'running' : 'waiting_for_approval',
        'pending_controls': [
          if (pending)
            {
              'kind': clarify ? 'clarify' : 'approval',
              'prompt_id': 'prompt_a',
              'execution_generation': generation,
              'command': 'echo fixture-secret',
              'question': 'Which target?',
              'choices': clarify ? ['A', 'B'] : ['once', 'deny']
            }
        ]
      };
  Future<void> init() async {
    SharedPreferences.setMockInitialValues({});
    c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()),
        runClientFactory: (root, key) =>
            RunClient(root, key, client: MockClient((r) async {
              requests.add(r);
              expect(r.followRedirects, isFalse);
              expect(r.headers['authorization'], 'Bearer fixture-secret');
              if (r.url.path.endsWith('capabilities')) {
                return http.Response(
                    jsonEncode({
                      'features': {
                        ...capabilities['features'] as Map,
                        'run_approval_response': approvalSupported
                      },
                      'endpoints': {
                        ...capabilities['endpoints'] as Map,
                        'run_approval': {'method': 'POST', 'path': approvalPath}
                      }
                    }),
                    200);
              }
              if (r.method == 'POST') {
                pending = false;
                return http.Response(
                    jsonEncode(legacyReceipt
                        ? {
                            'object': 'hermes.run.approval_response',
                            'resolved': 1
                          }
                        : {
                            'run_id': 'run_a',
                            'prompt_id': 'prompt_a',
                            'status': 'resolved'
                          }),
                    responseCode);
              }
              await holdGet?.future;
              return http.Response(jsonEncode(snapshot()), 200);
            })));
    await c.load();
    await c.addConnection(
        {'id': 'h', 'name': 'H', 'type': 'hermes', 'url': 'https://host'},
        'fixture-secret');
    final s = ChatSession(id: 'a', connectionId: 'h', model: 'm');
    c.sessions.add(s);
    c.current = s;
    final client = RunClient('https://host', 'fixture-secret');
    final op = await client.prepare(RunLedger(c.store.secrets),
        local: 'a',
        input: 'original',
        model: 'm',
        instructions: '',
        history: [],
        authorityEpoch: c.connections.single['authorityEpoch']);
    client.close();
    op.data.addAll({'run': 'run_a', 'snapshot': snapshot()});
    c.runs['a'] = op;
  }

  Iterable<http.Request> get posts => requests.where((r) => r.method == 'POST');
  Future<void> mount(WidgetTester t,
      {double width = 390, double scale = 1}) async {
    t.view.physicalSize = Size(width, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: const EdgeInsets.only(bottom: 260)),
            child: child!),
        home: ChatHome(controller: c)));
  }

  Future<void> open(WidgetTester t) async {
    await t.tap(find.text(clarify ? 'Answer needed' : 'Review action'));
    await t.pumpAndSettle();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }
}

void main() {
  testWidgets('replacing ChatHome owner revokes an open sheet', (t) async {
    final f = NativeControlsFixture();
    await f.init();
    await f.mount(t);
    await f.open(t);
    final replacement = NativeControlsFixture();
    await replacement.init();
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: replacement.c)));
    await t.pumpAndSettle();
    final allow = find.text('Allow once');
    if (allow.evaluate().isNotEmpty) {
      await t.tap(allow);
      await t.pumpAndSettle();
    }
    expect(f.posts, isEmpty);
    await f.close(t);
    replacement.c.dispose();
  });
  test('public control rejects a generation not in canonical pending snapshot',
      () async {
    final f = NativeControlsFixture();
    await f.init();
    final client = RunClient('https://host', 'fixture-secret',
        client: MockClient((r) async {
      fail('Stale public control must not issue HTTP');
    }));
    client.capabilities = {
      'features': {'run_approval_response': true},
      'endpoints': {
        'run_approval': {'method': 'POST', 'path': '/v1/runs/{run_id}/approval'}
      }
    };
    await expectLater(
        client.respondControl(f.c.currentRun!,
            requestId: 'prompt_a',
            generation: 2,
            choice: 'once',
            isCurrent: () => true),
        throwsStateError);
    client.close();
    f.c.dispose();
  });
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  for (final clarify in [false, true]) {
    for (final narrow in [false, true]) {
      testWidgets(
          'actual ${clarify ? 'clarify' : 'approval'} ${narrow ? '360 2x' : '390'} keyboard exact HTTP flow',
          (t) async {
        final f = NativeControlsFixture(clarify: clarify);
        await f.init();
        await f.mount(t, width: narrow ? 360 : 390, scale: narrow ? 2 : 1);
        await f.open(t);
        expect(find.textContaining('fixture-secret'), findsNothing);
        if (clarify) {
          await t.tap(find.text('A'));
          await t.pump();
        }
        final button =
            find.widgetWithText(FilledButton, clarify ? 'Send' : 'Allow once');
        await t.ensureVisible(button);
        await t.tap(button);
        await t.tap(button);
        // Settle this control transaction, not the ongoing thinking animation
        // plus unrelated two-second status polling. Keep exact wire assertions.
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        await t.pump();
        expect(f.posts.map((r) => r.url.path),
            ['/v1/runs/run_a/${clarify ? 'clarify' : 'approval'}']);
        expect(jsonDecode(f.posts.single.body), {
          'request_id': 'prompt_a',
          'execution_generation': 3,
          if (clarify) 'answer': 'A' else 'choice': 'once'
        });
        final paths =
            f.requests.map((r) => '${r.method} ${r.url.path}').toList();
        expect(paths, [
          'GET /v1/capabilities',
          'GET /v1/runs/run_a',
          'GET /v1/runs/run_a',
          'POST /v1/runs/run_a/${clarify ? 'clarify' : 'approval'}',
          'GET /v1/runs/run_a'
        ]);
        expect(f.c.currentRun!.snapshot.terminal, isFalse);
        expect(t.takeException(), isNull);
        await f.close(t);
      });
    }
  }
  for (final mode in [
    'native settled',
    'source changed',
    '409',
    'legacy',
    'unsupported',
    'foreign endpoint',
    'stale generation'
  ]) {
    testWidgets('actual approval $mode fails honestly without new chat',
        (t) async {
      final f = NativeControlsFixture();
      await f.init();
      if (mode == 'unsupported') f.approvalSupported = false;
      if (mode == 'foreign endpoint') {
        f.approvalPath = 'https://evil.invalid/approval';
      }
      await f.mount(t);
      await f.open(t);
      if (mode == 'native settled') f.pending = false;
      if (mode == 'stale generation') f.generation = 4;
      if (mode == '409') f.responseCode = 409;
      if (mode == 'legacy') f.legacyReceipt = true;
      if (mode == 'source changed') f.holdGet = Completer<void>();
      await t.tap(find.text('Allow once'));
      await t.pump();
      if (mode == 'source changed') {
        f.c.connections[0] = Map<String, dynamic>.from(f.c.connections.single);
        f.c.notifyListeners();
        f.holdGet!.complete();
      }
      await t.pumpAndSettle();
      expect(f.posts.length, ['409', 'legacy'].contains(mode) ? 1 : 0);
      expect(f.posts.any((r) => r.url.path.contains('chat')), isFalse);
      if (mode == '409') {
        expect(find.textContaining('answered elsewhere'), findsOneWidget);
      }
      if (mode == 'legacy') {
        expect(find.textContaining('not confirmed'), findsOneWidget);
      }
      expect(t.takeException(), isNull);
      await f.close(t);
    });
  }
}
