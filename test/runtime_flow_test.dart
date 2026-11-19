import 'dart:async';
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

const runtimeCapabilities = {
  'features': {
    'run_submission': true,
    'run_status': true,
    'run_events_sse': true,
    'run_steer': true,
    'run_stop': true,
    'runs_idempotency': {'supported': true}
  },
  'endpoints': {
    'runs': {'method': 'POST', 'path': '/v1/runs'},
    'run_status': {'method': 'GET', 'path': '/v1/runs/{run_id}'},
    'run_events': {'method': 'GET', 'path': '/v1/runs/{run_id}/events'},
    'run_steer': {'method': 'POST', 'path': '/v1/runs/{run_id}/steer'},
    'run_stop': {'method': 'POST', 'path': '/v1/runs/{run_id}/stop'}
  }
};

class RealHttp extends HttpOverrides {}

class RuntimeFixture {
  late HttpServer server;
  HttpResponse? stream;
  bool completed = false;
  String statusSessionId = 'external_chat';
  Object? terminalOutput = 'Authoritative final response';
  bool loseFirstAck = false;
  final inputBytes = <String>[];
  final inputKeys = <String?>[];
  int submissions = 0;
  int sequence = 0;
  final guides = <String>[];
  bool stopping = false;
  final requests = <String>[];
  final inputs = <Map<String, dynamic>>[];
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      requests.add('${r.method} ${r.uri.path}');
      if (r.uri.path.endsWith('/events')) {
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.bufferOutput = false;
        stream = r.response;
        emit('message.delta', {'delta': 'Visible response in progress'});
        return;
      }
      r.response.headers.contentType = ContentType.json;
      if (r.uri.path.endsWith('/capabilities')) {
        r.response.write(jsonEncode(runtimeCapabilities));
      } else if (r.uri.path == '/api/sessions') {
        r.response.write(
            '{"data":[{"id":"external_chat","source":"api_server","title":"External chat","model":"original-model"}],"limit":50,"offset":0,"has_more":false}');
      } else if (r.uri.path.endsWith('/messages')) {
        r.response.write(
            '{"session_id":"external_chat","data":[{"role":"user","content":"External context"},{"role":"assistant","content":"Existing reply"},{"role":"assistant","content":"PRIVATE HIDDEN ROW","display_kind":"hidden"}],"pagination":{"returned":3,"limit":100}}');
      } else if (r.uri.path.endsWith('/steer')) {
        guides.add((jsonDecode(await utf8.decoder.bind(r).join())
            as Map)['input'] as String);
        r.response.write('{"run_id":"run_fixture","accepted":true}');
      } else if (r.uri.path.endsWith('/stop')) {
        stopping = true;
        r.response.write('{"run_id":"run_fixture","status":"stopping"}');
      } else if (r.method == 'POST') {
        final body = await utf8.decoder.bind(r).join();
        inputBytes.add(body);
        inputKeys.add(r.headers.value('Idempotency-Key'));
        inputs.add(jsonDecode(body) as Map<String, dynamic>);
        submissions++;
        if (loseFirstAck && submissions == 1) {
          (await r.response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        r.response.statusCode = 202;
        r.response.write('{"run_id":"run_fixture","status":"running"}');
      } else {
        r.response.write(jsonEncode({
          'run_id': 'run_fixture',
          'session_id': statusSessionId,
          'status': completed
              ? 'completed'
              : stopping
                  ? 'stopping'
                  : 'running',
          if (completed) 'output': terminalOutput
        }));
      }
      await r.response.close();
    });
  }

  void emit(String event, Map<String, dynamic> fields) {
    stream!.write('id: ${sequence++}\ndata: ${jsonEncode({
          'event': event,
          'run_id': 'run_fixture',
          ...fields
        })}\n\n');
    unawaited(stream!.flush());
  }

  Future<void> close() async {
    await stream?.close();
    await server.close(force: true);
  }
}

void main() {
  for (final compact in [false, true]) {
    testWidgets('real Runs UI stream completion guide stop compact=$compact',
        (tester) async {
      HttpOverrides.global = null;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(compact ? 360 : 390, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late RuntimeFixture fixture;
      late ChatController c;
      await tester.runAsync(() async {
        fixture = RuntimeFixture();
        await fixture.start();
        SharedPreferences.setMockInitialValues({});
        c = ChatController(SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()));
        await c.load();
        final connection = {
          'id': 'h',
          'name': 'Hermes',
          'type': 'hermes',
          'url': 'http://127.0.0.1:${fixture.server.port}'
        };
        await c.addConnection(connection, 'fixture');
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await http.runWithClient(
          () => tester.pumpWidget(MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(compact ? 2 : 1),
                      viewInsets: EdgeInsets.only(bottom: compact ? 220 : 0)),
                  child: child!),
              home: ChatHome(controller: c))),
          () => IOClient(RealHttp().createHttpClient(null)));
      Future<void> network() async {
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
      }

      await tester.tap(find.byTooltip('Open navigation menu'));
      await network();
      await tester.tap(find.text('External chat'));
      await network();
      await tester.pumpAndSettle();
      expect(find.text('Continue conversation'), findsNothing);
      expect(fixture.submissions, 0,
          reason: 'Opening must never submit or replay input');
      expect(c.current!.remoteSessionId, 'external_chat');
      await tester.enterText(find.byKey(const Key('composer')), 'New input');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await network();
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      await tester.pump();
      expect(c.streamingText, 'Visible response in progress',
          reason:
              '${fixture.requests} ${c.currentRun?.snapshot.data} ${c.error}');
      expect(
          find.byWidgetPredicate((w) =>
              w is MessageView && w.text == 'Visible response in progress'),
          findsOneWidget,
          reason:
              '${tester.widgetList<MessageView>(find.byType(MessageView)).map((v) => v.text).toList()}');
      await tester.enterText(
          find.byKey(const Key('composer')), 'Keep this draft');
      await tester.pump();
      expect(find.byTooltip('Guide current work'), findsOneWidget);
      await tester.tap(find.byTooltip('Guide current work'));
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      expect(fixture.guides, ['Keep this draft']);
      expect(fixture.submissions, 1);
      expect(c.outbox, isEmpty);
      await tester.enterText(
          find.byKey(const Key('composer')), 'Keep this draft');
      await tester.pump();
      await tester.tap(find.byTooltip('Stop current work'));
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      expect(fixture.stopping, isTrue);
      expect(c.currentRun!.snapshot.status, 'stopping');
      expect(c.runPending, isTrue);
      await tester.runAsync(() async {
        fixture.completed = true;
        fixture
            .emit('run.completed', {'output': 'Authoritative final response'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      await tester.pump();
      expect(find.text('Authoritative final response'), findsOneWidget);
      expect(find.text('Visible response in progress'), findsNothing);
      expect(c.runPending, isFalse);
      expect(fixture.submissions, 1);
      expect(fixture.inputs.single,
          {'input': 'New input', 'session_id': 'external_chat'});
      expect(c.current!.messages.first.content, 'External context');
      expect(find.text('Keep this draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        c.dispose();
        await fixture.close();
      });
    });
  }
}
