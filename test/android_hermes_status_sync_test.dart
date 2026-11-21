import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_activity/activity_owner.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

class RealHttp extends HttpOverrides {}

const runtimeCapabilities = {
  'features': {
    'run_submission': true,
    'run_status': true,
    'run_events_sse': true,
    'runs_idempotency': {'supported': true},
  },
  'endpoints': {
    'runs': {'method': 'POST', 'path': '/v1/runs'},
    'run_status': {'method': 'GET', 'path': '/v1/runs/{run_id}'},
    'run_events': {'method': 'GET', 'path': '/v1/runs/{run_id}/events'},
  },
};

class SyncServer {
  late HttpServer server;
  final requests = <String>[];
  final bodies = <String>[];
  final keys = <String?>[];
  final events = <HttpResponse>[];
  bool completed = false;
  bool supported = true;
  bool breakStatus = false;
  Completer<void>? statusEntered, statusRelease;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      if (request.uri.path.endsWith('/events')) {
        events.add(request.response);
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        request.response.bufferOutput = false;
        request.response.write('id: 1\ndata: {"event":"message.delta",'
            '"run_id":"run_original","delta":"partial answer"}\n\n');
        await request.response.flush();
        return;
      }
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/capabilities')) {
        request.response
            .write(jsonEncode(supported ? runtimeCapabilities : {}));
      } else if (request.method == 'POST') {
        bodies.add(await utf8.decoder.bind(request).join());
        keys.add(request.headers.value('Idempotency-Key'));
        request.response.statusCode = 202;
        request.response.write('{"run_id":"run_original","status":"running"}');
      } else {
        final release = statusRelease;
        if (release != null) {
          statusEntered!.complete();
          await release.future;
          statusRelease = null;
        }
        if (breakStatus) {
          (await request.response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        request.response.write(jsonEncode({
          'run_id': 'run_original',
          'status': completed ? 'completed' : 'running',
          if (completed) 'output': 'Complete original answer',
        }));
      }
      await request.response.close();
    });
  }

  Future<ChatController> controller({CoreFactory? coreFactory}) async {
    SharedPreferences.setMockInitialValues({});
    final controller = ChatController(
      SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets(),
      ),
      coreFactory: coreFactory,
    );
    await controller.load();
    await controller.addConnection({
      'id': 'hermes',
      'name': 'Original Hermes',
      'type': 'hermes',
      'url': 'http://127.0.0.1:${server.port}',
    }, 'controlled-fixture');
    await controller.newSession(controller.connections.single, 'model', '');
    return controller;
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}

Future<void> waitFor(bool Function() ready) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  testWidgets('Android ignores advertised activity SSE; desktop keeps previews',
      (tester) async {
    await tester.runAsync(() => http.runWithClient(() async {
          final server = SyncServer();
          await server.start();
          final controller = await server.controller();
          final owner = ActivityOwner(controller);
          final snapshots = <ScopedRunSnapshot>[];
          final subscription =
              controller.scopedRunSnapshots.listen(snapshots.add);
          try {
            expect(await controller.send('original input'), isTrue);
            await Future<void>.delayed(const Duration(milliseconds: 100));
            if (defaultTargetPlatform == TargetPlatform.android) {
              expect(server.events, isEmpty);
              controller.observeRunEvent(
                  snapshots.single,
                  {
                    'run_id': 'run_original',
                    'event': 'message.delta',
                    'delta': 'must not render',
                  },
                  cursor: '2');
              expect(controller.streamingText, isNull);
              expect(owner.model.parents, isNotEmpty);
            } else {
              await waitFor(() => controller.streamingText != null);
              expect(server.events, hasLength(1));
              expect(controller.streamingText, 'partial answer');
            }
            expect(server.bodies, hasLength(1));
            expect(controller.current!.messages, isEmpty);
            expect(controller.runPending, isTrue);
          } finally {
            await subscription.cancel();
            owner.dispose();
            controller.dispose();
            await server.close();
          }
        }, () => IOClient(RealHttp().createHttpClient(null))));
  },
      variant: TargetPlatformVariant(
          {TargetPlatform.android, TargetPlatform.linux}));

  testWidgets('Android revokes an interrupted admission status response',
      (tester) async {
    await tester.runAsync(() => http.runWithClient(() async {
          final server = SyncServer()
            ..statusEntered = Completer<void>()
            ..statusRelease = Completer<void>();
          await server.start();
          final controller = await server.controller();
          try {
            final sending = controller.send('original input');
            await server.statusEntered!.future;
            final operation = controller.currentRun!;
            final journalKey = 'run.v1.${controller.current!.id}';
            final journal = await controller.store.secrets.read(journalKey);
            controller.pauseRuns(true);
            server.completed = true;
            server.statusRelease!.complete();
            await sending;
            expect(controller.currentRun, same(operation));
            expect(controller.current!.messages, isEmpty);
            expect(await controller.store.secrets.read(journalKey), journal);
            expect(controller.runObservationProblem, isNull,
                reason: 'Revocation is not a failed foreground observation');
            final requests = server.requests.length;
            await Future<void>.delayed(const Duration(milliseconds: 2100));
            expect(server.requests, hasLength(requests));
            controller.pauseRuns(false);
            await waitFor(() => operation.committed);
            expect(controller.current!.messages.map((m) => m.content),
                ['original input', 'Complete original answer']);
            expect(server.bodies, hasLength(1));
            expect(server.events, isEmpty);
          } finally {
            controller.dispose();
            await server.close();
          }
        }, () => IOClient(RealHttp().createHttpClient(null))));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final recovery in ['foreground', 'recreated', 'broken GET']) {
    testWidgets('Android $recovery sync settles only the original operation',
        (tester) async {
      await tester.runAsync(() => http.runWithClient(() async {
            final server = SyncServer();
            await server.start();
            var controller = await server.controller();
            var owner = ActivityOwner(controller);
            try {
              await controller.send('original input');
              final operation = controller.currentRun!;
              final sessionId = controller.current!.id;
              final data = jsonDecode(jsonEncode(operation.data));
              final journalKey = 'run.v1.$sessionId';
              final journal = await controller.store.secrets.read(journalKey);
              final payload = operation.payload;
              final key = operation.key;
              if (recovery == 'broken GET') {
                server.breakStatus = true;
                await controller.checkRunStatus();
                expect(controller.runObservationProblem,
                    'Reconnecting to check your reply');
                expect(controller.currentRun!.data, data);
                expect(
                    await controller.store.secrets.read(journalKey), journal);
                server.breakStatus = false;
              }
              controller.pauseRuns(true);
              owner.setPaused(true);
              server.completed = true;
              if (recovery == 'recreated') {
                final store = controller.store;
                owner.dispose();
                controller.dispose();
                await store.preferences.reload();
                controller = ChatController(SaathiStore(
                    preferences: store.preferences, secrets: store.secrets));
                await controller.load();
                owner = ActivityOwner(controller);
                expect(controller.currentRun!.data, data);
                expect(await store.secrets.read(journalKey), journal);
              }
              var notifications = 0;
              controller.onReplyReceived = (_) => notifications++;
              expect(controller.current!.id, sessionId);
              expect(controller.runPending, isTrue);
              expect(controller.current!.messages, isEmpty);
              controller.pauseRuns(false);
              owner.setPaused(false);
              await waitFor(() => controller.currentRun!.committed);
              await controller.checkRunStatus();
              expect(controller.currentRun!.key, key);
              expect(controller.currentRun!.payload, payload);
              expect(controller.currentRun!.sessionId, operation.sessionId);
              expect(controller.current!.id, sessionId);
              expect(controller.current!.messages.map((m) => m.content),
                  ['original input', 'Complete original answer']);
              expect(controller.current!.messages.last.id, 'run-$key');
              expect(notifications, 1);
              expect(server.bodies, [payload]);
              expect(server.keys, [key]);
              expect(server.events, isEmpty);
              expect(controller.runPending, isFalse);
            } finally {
              owner.dispose();
              controller.dispose();
              await server.close();
            }
          }, () => IOClient(RealHttp().createHttpClient(null))));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('Android failed status reads exhaust a finite budget and recover',
      (tester) async {
    final server = SyncServer();
    late ChatController controller;
    await tester.runAsync(() => http.runWithClient(() async {
          await server.start();
          controller = await server.controller();
          await controller.send('original input');
        }, () => IOClient(RealHttp().createHttpClient(null))));
    Future<void> flush() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
    }

    try {
      final operation = controller.currentRun!;
      server.breakStatus = true;
      // Move the existing foreground timer into the controlled test clock.
      await http.runWithClient(() async {
        controller.pauseRuns(false);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(seconds: 8));
          await flush();
        }
        final reads = server.requests
            .where((r) => r == 'GET /v1/runs/run_original')
            .length;
        expect(reads, 5);
        expect(controller.runObservationProblem, contains('Use Check status'));
        expect(controller.runPending, isTrue);
        expect(controller.current!.messages, isEmpty);
        await tester.pump(const Duration(seconds: 60));
        await flush();
        expect(server.requests.where((r) => r == 'GET /v1/runs/run_original'),
            hasLength(reads));
        server.breakStatus = false;
        await tester.runAsync(() => controller.checkRunStatus());
        expect(controller.runObservationProblem, isNull);
        server.completed = true;
        controller.pauseRuns(false);
        await tester.pump(const Duration(seconds: 2));
        await flush();
        expect(operation.committed, isTrue);
        expect(server.bodies, [operation.payload]);
        expect(server.keys, [operation.key]);
        expect(controller.current!.messages.map((m) => m.content),
            ['original input', 'Complete original answer']);
        expect(server.events, isEmpty);
      }, () => IOClient(RealHttp().createHttpClient(null)));
    } finally {
      controller.dispose();
      await tester.runAsync(server.close);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final mutation in ['epoch', 'url']) {
    testWidgets(
        'Android rejects original-run recovery after $mutation mutation',
        (tester) async {
      await tester.runAsync(() => http.runWithClient(() async {
            final server = SyncServer();
            await server.start();
            final controller = await server.controller();
            try {
              await controller.send('original input');
              final operation = controller.currentRun!;
              final journalKey = 'run.v1.${controller.current!.id}';
              final journal = await controller.store.secrets.read(journalKey);
              controller.pauseRuns(true);
              controller.connections[0] = {
                ...controller.connections.single,
                if (mutation == 'epoch') 'authorityEpoch': 'replacement',
                if (mutation == 'url')
                  'url': 'http://127.0.0.1:${server.server.port}/replacement',
              };
              server.completed = true;
              final reads = server.requests.length;
              controller.pauseRuns(false);
              await controller.checkRunStatus();
              expect(server.requests, hasLength(reads));
              expect(controller.currentRun, same(operation));
              expect(controller.current!.messages, isEmpty);
              expect(controller.runPending, isTrue);
              expect(await controller.store.secrets.read(journalKey), journal);
              expect(server.bodies, hasLength(1));
            } finally {
              controller.dispose();
              await server.close();
            }
          }, () => IOClient(RealHttp().createHttpClient(null))));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final injectedCore in [false, true]) {
    testWidgets('Android requires durable Runs with injectedCore=$injectedCore',
        (tester) async {
      await tester.runAsync(() => http.runWithClient(() async {
            final server = SyncServer()..supported = false;
            await server.start();
            final controller = await server.controller(
                coreFactory: injectedCore ? () => SaathiCore() : null);
            try {
              expect(await controller.send('must stay unsent'), isFalse);
              expect(server.bodies, isEmpty,
                  reason: 'No Runs or compatibility inference may be posted');
              expect(server.requests, ['GET /v1/capabilities']);
              expect(controller.current!.messages, isEmpty);
              expect(controller.currentRun, isNull);
              expect(controller.error, contains('durable Runs'));
              expect(controller.error, contains('original server'));
            } finally {
              controller.dispose();
              await server.close();
            }
          }, () => IOClient(RealHttp().createHttpClient(null))));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
