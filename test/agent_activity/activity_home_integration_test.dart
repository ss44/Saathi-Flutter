import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/agent_activity/activity_strip.dart';
import '../agent_runs_test.dart' show capabilities;

class _RealHttp extends HttpOverrides {}

void main() {
  for (final approval in [false, true]) {
    testWidgets(
        'real pending run streams activity above composer with approval=$approval',
        (t) async {
      HttpOverrides.global = null;
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(360, 800);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      SharedPreferences.setMockInitialValues({});
      late HttpServer server;
      final paths = <String>[];
      final streams = <HttpResponse>[];
      var pending = approval;
      final posts = <String>[];
      Map<String, dynamic> snapshot() => {
            'run_id': 'run_1',
            'admission_id': 'adm_1',
            'execution_generation': 3,
            'status': pending ? 'waiting_for_approval' : 'running',
            'pending_controls': [
              if (pending)
                {
                  'kind': 'approval',
                  'prompt_id': 'prompt_1',
                  'execution_generation': 3,
                  'command': 'echo fixture',
                  'choices': ['once', 'deny']
                }
            ]
          };
      await t.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((r) async {
          paths.add(r.uri.path);
          if (r.uri.path.endsWith('/events')) {
            expect(
                r.headers.value('Last-Event-ID'), streams.isEmpty ? null : '1');
            r.response.bufferOutput = false;
            r.response.headers.contentType =
                ContentType('text', 'event-stream');
            streams.add(r.response);
            r.response.write(
                'id: 1\ndata: {"event":"subagent.start","run_id":"run_1","seq":1,"subagent_id":"child","child_session_id":"session_child","goal":"Inspect files"}\n\n');
            await r.response.flush();
            return;
          }
          r.response.headers.contentType = ContentType.json;
          if (r.uri.path == '/api/sessions/session_child/messages') {
            r.response.write(
                '{"session_id":"session_child","data":[{"role":"assistant","content":"Public child result"}],"pagination":{"returned":1,"limit":100}}');
          } else if (r.uri.path.endsWith('capabilities')) {
            r.response.write(jsonEncode({
              ...capabilities,
              'features': {
                ...capabilities['features'] as Map,
                'run_events_sse': true,
                'run_approval_response': true
              },
              'endpoints': {
                ...capabilities['endpoints'] as Map,
                'run_approval': {
                  'method': 'POST',
                  'path': '/v1/runs/{run_id}/approval'
                },
                'run_events': {
                  'method': 'GET',
                  'path': '/v1/runs/{run_id}/events'
                }
              }
            }));
          } else if (r.method == 'POST') {
            posts.add(r.uri.path);
            final body = await utf8.decoder.bind(r).join();
            if (r.uri.path.endsWith('/approval')) {
              expect(jsonDecode(body), {
                'request_id': 'prompt_1',
                'execution_generation': 3,
                'choice': 'once'
              });
              pending = false;
              r.response.write(
                  '{"run_id":"run_1","prompt_id":"prompt_1","status":"resolved"}');
            } else {
              r.response.statusCode = 202;
              r.response.write(jsonEncode(snapshot()));
            }
          } else {
            r.response.write(jsonEncode(snapshot()));
          }
          await r.response.close();
        });
      });
      late ChatController c;
      ScopedRunSnapshot? captured;
      await t.runAsync(() async {
        c = ChatController(SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()));
        await c.load();
        await c.addConnection({
          'id': 'h',
          'name': 'Original',
          'type': 'hermes',
          'url': 'http://127.0.0.1:${server.port}'
        }, 'fixture');
        await c.newSession(c.connections.single, 'model', '');
        c.scopedRunSnapshots.listen((s) => captured = s);
      });
      await http.runWithClient(
          () => t.pumpWidget(MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(2),
                      viewInsets:
                          EdgeInsets.only(bottom: approval ? 300 : 220)),
                  child: child!),
              home: ChatHome(controller: c))),
          () => IOClient(_RealHttp().createHttpClient(null)));
      await t.runAsync(() async {
        expect(await c.send('inspect'), true, reason: '${c.error} $paths');
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      for (var i = 0; i < 12; i++) {
        await t.pump();
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      await t.pump();
      expect(find.byType(AgentActivityStrip), findsOneWidget);
      expect(find.text(approval ? 'Needs your attention' : 'Agent activity'),
          findsOneWidget);
      expect(
          t
              .getBottomLeft(find
                  .text(approval ? 'Needs your attention' : 'Agent activity'))
              .dy,
          lessThan(t.getTopLeft(find.byKey(const Key('composer'))).dy));
      if (approval) {
        await t.tap(find.text('Needs your attention'));
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('Inspect files'));
        expect(find.textContaining('Read-only history'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.tap(find.byTooltip('Close activity'));
        await t.pumpAndSettle();
        final draft = List.filled(30, 'long draft').join(' ');
        await t.enterText(find.byKey(const Key('composer')), draft);
        await t.pump();
        expect(c.submit('Queued while approval is pending'), isTrue);
        await t.pump();
        final feedbackScroll = find
            .descendant(
                of: find.byKey(const Key('chat-feedback')),
                matching: find.byType(Scrollable))
            .first;
        await t.scrollUntilVisible(find.text('Cancel'), 30,
            scrollable: feedbackScroll);
        await Scrollable.ensureVisible(t.element(find.text('Cancel')),
            alignment: .5);
        await t.pumpAndSettle();
        expect(find.text('Cancel').hitTestable(), findsOneWidget);
        await t.tap(find.text('Cancel'));
        await t.pump();
        expect(c.outbox, isEmpty);
        expect(find.text('Review action').hitTestable(), findsOneWidget);
        expect(find.text('Review action'), findsOneWidget);
        expect(t.getBottomLeft(find.text('Review action')).dy,
            lessThan(t.getTopLeft(find.byKey(const Key('composer'))).dy));
        expect(t.takeException(), isNull);
        await t.tap(find.text('Review action'));
        for (var i = 0; i < 12; i++) {
          await t.pump(const Duration(milliseconds: 50));
          await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        await t.ensureVisible(find.text('Allow once'));
        await t.tap(find.text('Allow once'));
        for (var i = 0; i < 12; i++) {
          await t.pump(const Duration(milliseconds: 50));
          await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        expect(posts, ['/v1/runs', '/v1/runs/run_1/approval']);
        Navigator.of(t.element(find.byType(ChatHome))).pop();
        await t.pumpAndSettle();
        expect(find.text(draft), findsOneWidget);
        expect(t.takeException(), isNull);
      }
      await t.tap(find.text('Agent activity'));
      await t.pumpAndSettle();
      expect(paths.where((p) => p.endsWith('/events')).length, 1,
          reason: paths.toString());
      expect(find.text('Inspect files'), findsOneWidget);
      expect(find.textContaining('Read-only history'), findsOneWidget);
      expect(paths.where((p) => p.endsWith('/events')).length, 1);
      if (approval) {
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
        await t.runAsync(() async {
          for (final stream in streams) {
            await stream.close();
          }
          await server.close(force: true);
        });
        return;
      }
      final old = c.runs.remove(c.current!.id)!;
      c.notifyListeners();
      await t.pump();
      expect(captured!.isCurrent(), false,
          reason: 'send/control authority is operation-scoped');
      expect(find.text('Inspect files'), findsOneWidget,
          reason: 'read-only old run survives later turns');
      c.runs[c.current!.id] = old;
      await t.tap(find.text('Inspect files'));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 50));
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      expect(paths, contains('/api/sessions/session_child/messages'));
      await t.drag(find.byType(ListView).last, const Offset(0, -500));
      await t.pumpAndSettle();
      expect(find.text('Public child result'), findsOneWidget);
      expect(find.byKey(const Key('composer')), findsNothing);
      await t.pageBack();
      await t.pumpAndSettle();
      final originalChat = c.current!;
      await t.tap(find.text('Agent activity'));
      await t.pumpAndSettle();
      final otherChat =
          ChatSession(id: 'other', connectionId: 'h', model: 'model');
      c.sessions.add(otherChat);
      c.current = otherChat;
      c.notifyListeners();
      await t.pump();
      await t.tap(find.widgetWithText(ListTile, 'New conversation'));
      await t.pumpAndSettle();
      expect(identical(c.current, originalChat), true);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 12; i++) {
        await t.pump();
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      expect(paths.where((p) => p.endsWith('/events')).length, 2);
      c.connections[0] = {...c.connections.single, 'authorityEpoch': 'rotated'};
      c.notifyListeners();
      await t.pump();
      expect(captured!.isObservable(), false);
      expect(find.text('Agent activity'), findsNothing);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.runAsync(() async {
        for (final s in streams) {
          await s.close();
        }
        await server.close(force: true);
      });
    });
  }
}
