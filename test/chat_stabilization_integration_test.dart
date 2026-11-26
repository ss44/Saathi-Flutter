import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/optimizer_settings.dart';

import 'runtime_flow_test.dart' show RealHttp, runtimeCapabilities;

void main() {
  for (final width in [360.0, 390.0]) {
    testWidgets('ChatHome $width 2x keyboard approval child stream optimizer',
        (t) async {
      HttpOverrides.global = null;
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 800);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final keyboard = ValueNotifier(240.0);
      var approval = true;
      var completed = false;
      var sequence = 0;
      String? serverSession;
      final streams = <HttpResponse>[];
      final posts = <String>[];
      final bodies = <Map<String, dynamic>>[];
      late HttpServer server;
      late ChatController c;
      Future<void> emit(String event, Map<String, Object?> data) async {
        for (final stream in streams) {
          stream.write('id: ${sequence++}\ndata: ${jsonEncode({
                'event': event,
                'run_id': 'run_combined',
                ...data
              })}\n\n');
          await stream.flush();
        }
      }

      Map<String, Object?> status() => {
            'run_id': 'run_combined',
            'admission_id': 'admission_combined',
            if (serverSession != null) 'session_id': serverSession,
            'execution_generation': 3,
            'status': completed
                ? 'completed'
                : approval
                    ? 'waiting_for_approval'
                    : 'running',
            if (completed) 'output': 'Authoritative combined result',
            'pending_controls': [
              if (approval)
                {
                  'kind': 'approval',
                  'prompt_id': 'combined_prompt',
                  'execution_generation': 3,
                  'command': 'echo controlled',
                  'choices': ['once', 'deny']
                }
            ]
          };
      await t.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((r) async {
          if (r.uri.path.endsWith('/events')) {
            r.response.bufferOutput = false;
            r.response.headers.contentType =
                ContentType('text', 'event-stream');
            streams.add(r.response);
            await emit('subagent.start', {
              'seq': 1,
              'subagent_id': 'combined_child',
              'child_session_id': 'child_history',
              'goal': 'Inspect combined fixture'
            });
            await emit('message.delta', {'delta': 'Visible combined stream'});
            return;
          }
          r.response.headers.contentType = ContentType.json;
          if (r.uri.path.endsWith('/capabilities')) {
            r.response.write(jsonEncode({
              ...runtimeCapabilities,
              'features': {
                ...runtimeCapabilities['features'] as Map,
                'run_approval_response': true
              },
              'endpoints': {
                ...runtimeCapabilities['endpoints'] as Map,
                'run_approval': {
                  'method': 'POST',
                  'path': '/v1/runs/{run_id}/approval'
                }
              }
            }));
          } else if (r.uri.path == '/v1/models') {
            r.response.write('{"data":[{"id":"rewrite-model"}]}');
          } else if (r.method == 'POST') {
            posts.add(r.uri.path);
            final body = jsonDecode(await utf8.decoder.bind(r).join())
                as Map<String, dynamic>;
            bodies.add(body);
            if (r.uri.path.endsWith('/approval')) {
              expect(body, {
                'request_id': 'combined_prompt',
                'execution_generation': 3,
                'choice': 'once'
              });
              approval = false;
              r.response.write(
                  '{"run_id":"run_combined","prompt_id":"combined_prompt","status":"resolved"}');
            } else if (r.uri.path.endsWith('/chat/completions')) {
              r.response.write(jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'Improved combined draft'}
                  }
                ]
              }));
            } else {
              serverSession = body['session_id'] as String?;
              r.response.statusCode = 202;
              r.response.write(jsonEncode(status()));
            }
          } else {
            r.response.write(jsonEncode(status()));
          }
          await r.response.close();
        });
        SharedPreferences.setMockInitialValues({});
        c = ChatController(SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()));
        await c.load();
        await c.addConnection({
          'id': 'hermes',
          'name': 'Original Hermes',
          'type': 'hermes',
          'url': 'http://127.0.0.1:${server.port}'
        }, 'controlled');
        await c.newSession(c.connections.single, 'original-model', '');
        await c.addConnection({
          'id': 'rewrite',
          'name': 'Separate rewrite',
          'type': 'openai',
          'url': 'http://127.0.0.1:${server.port}'
        }, 'controlled');
        await c.saveOptimizerSelection(const OptimizerSelection(
            connectionId: 'rewrite', model: 'rewrite-model'));
      });
      await http.runWithClient(
          () => t.pumpWidget(MaterialApp(
              builder: (context, child) => ValueListenableBuilder<double>(
                  valueListenable: keyboard,
                  builder: (_, inset, unused) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                          textScaler: TextScaler.linear(2),
                          viewInsets: EdgeInsets.only(bottom: inset)),
                      child: child!)),
              home: ChatHome(controller: c))),
          () => IOClient(RealHttp().createHttpClient(null)));
      Future<void> network() async {
        for (var i = 0; i < 12; i++) {
          await t.pump(const Duration(milliseconds: 30));
          await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
      }

      final composer = find.byKey(const Key('composer'));
      await t.enterText(composer, 'Start controlled work');
      await t.pump();
      await t.tap(find.byTooltip('Send'));
      await network();
      expect(c.streamingText, 'Visible combined stream');
      expect(find.text('Needs your attention').hitTestable(), findsOneWidget);
      final draft = List.filled(30, 'Keep this long draft').join(' ');
      await t.enterText(composer, draft);
      await t.pump();
      await t.longPress(find.byTooltip('Send'));
      await t.pump();
      expect(c.outbox, isEmpty);
      expect(t.widget<TextField>(composer).controller!.text, draft);
      expect(find.byTooltip('Enhance prompt'), findsNothing);
      expect(find.text('Review action').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Stop current work').hitTestable(), findsOneWidget);
      expect(
          t.getBottomLeft(find.byTooltip('Send')).dy, lessThanOrEqualTo(560));
      expect(t.takeException(), isNull);
      await t.tap(find.text('Needs your attention'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Inspect combined fixture'));
      expect(find.text('Inspect combined fixture'), findsOneWidget);
      await t.tap(find.byTooltip('Close activity'));
      await t.pumpAndSettle();
      // Organization uses the real mixed Drawer without disturbing admitted
      // work, the live child/stream, controls or this long keyboard draft.
      await t.tap(find.byTooltip('Open navigation menu'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Conversation actions'));
      await t.pumpAndSettle();
      await t.tap(find.text('Edit').last);
      await t.pumpAndSettle();
      expect(find.textContaining('Persona editing is unavailable'),
          findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('conversation-name')),
          'Combined renamed chat');
      await t.ensureVisible(find.text('Save').last);
      await t.tap(find.text('Save').last);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Conversation actions'));
      await t.pumpAndSettle();
      await t.tap(find.text('Archive').last);
      await t.pumpAndSettle();
      expect(c.organization.entry(c.identityOf(c.current!)).archived, isTrue);
      expect(c.runPending, isTrue);
      Navigator.of(t.element(find.byType(ChatHome))).pop();
      await t.pumpAndSettle();
      expect(t.widget<TextField>(composer).controller!.text, draft);
      expect(
          find.descendant(
              of: find.byType(AppBar),
              matching: find.text('Combined renamed chat')),
          findsOneWidget);
      await t.tap(find.text('Review action'));
      await network();
      await t.ensureVisible(find.text('Allow once'));
      await t.tap(find.text('Allow once'));
      await network();
      expect(posts, ['/v1/runs', '/v1/runs/run_combined/approval']);
      Navigator.of(t.element(find.byType(ChatHome))).pop();
      await t.pumpAndSettle();
      expect(t.widget<TextField>(composer).controller!.text, draft);
      expect(
          find.byTooltip('Guide current work').hitTestable(), findsOneWidget);
      await t.runAsync(() async {
        completed = true;
        await emit('run.completed', {});
      });
      await network();
      expect(c.runPending, isFalse);
      expect(c.current!.messages.last.content, 'Authoritative combined result');
      expect(c.current!.model, 'original-model');
      expect(streams, hasLength(1));
      await t.longPress(find.byTooltip('Send'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Enhance prompt'));
      await network();
      await t.tap(find.text('Enhance'));
      await network();
      keyboard.value = 0;
      await t.pumpAndSettle();
      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(composer).controller!.text,
          'Improved combined draft');
      keyboard.value = 240;
      await t.pumpAndSettle();
      await t.tap(find.text('Undo'));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(composer).controller!.text, draft);
      expect(c.current!.model, 'original-model');
      expect(posts, [
        '/v1/runs',
        '/v1/runs/run_combined/approval',
        '/v1/chat/completions'
      ]);
      expect(jsonEncode(bodies.last), isNot(contains('Start controlled work')));
      expect(
          jsonEncode(bodies.last), isNot(contains('Authoritative combined')));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      keyboard.dispose();
      await t.runAsync(() async {
        for (final stream in streams) {
          await stream.close();
        }
        await server.close(force: true);
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }
}
