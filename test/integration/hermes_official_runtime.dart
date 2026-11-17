import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RealHttp extends HttpOverrides {}

/// Explicit local compatibility probe, not part of hermetic CI. Run with:
/// flutter test test/integration/hermes_official_runtime.dart
/// HERMES_TEST_SOURCE/PYTHON may select another read-only source/venv.
void main() {
  testWidgets(
      'official server stub runtime existing conversation UI round trip',
      (tester) async {
    HttpOverrides.global = null;
    late Process server;
    late ChatController controller;
    late Directory home;
    final errors = StringBuffer();
    await tester.runAsync(() async {
      home = await Directory('.dart_tool').createTemp('hermes-runtime-');
      addTearDown(() async {
        await home.delete(recursive: true);
      });
      server = await Process.start(
          Platform.environment['HERMES_TEST_PYTHON'] ??
              '/opt/hermes/.venv/bin/python',
          [
            'tool/hermes_controlled_server.py',
            '--source',
            Platform.environment['HERMES_TEST_SOURCE'] ?? '/opt/hermes',
            '--home',
            home.path
          ]);
      addTearDown(() async {
        server.kill();
        await server.exitCode;
      });
      server.stderr.transform(utf8.decoder).listen(errors.write);
      final ready = await server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line.startsWith('{'))
          .timeout(const Duration(seconds: 60),
              onTimeout: () => throw StateError(
                  'Controlled server startup failed: $errors'));
      final config = jsonDecode(ready) as Map;
      SharedPreferences.setMockInitialValues({});
      controller = ChatController(SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets()));
      await controller.load();
      await controller.addConnection({
        'id': 'controlled',
        'name': 'Hermes controlled',
        'type': 'hermes',
        'url': config['url']
      }, config['key'] as String);
    });
    addTearDown(() async {
      controller.dispose();
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await http.runWithClient(
        () => tester
            .pumpWidget(MaterialApp(home: ChatHome(controller: controller))),
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
    for (var i = 0;
        i < 40 && find.text('External chat').evaluate().isEmpty;
        i++) {
      await network();
    }
    expect(find.text('External chat'), findsOneWidget,
        reason: errors.toString());
    await tester.tap(find.text('External chat'));
    await network();
    for (var i = 0;
        i < 40 && find.text('Existing reply').evaluate().isEmpty;
        i++) {
      await network();
    }
    await tester.tap(find.text('Continue conversation'));
    await network();
    for (var i = 0; i < 40 && controller.current == null; i++) {
      await network();
    }
    expect(controller.current!.remoteSessionId, 'external_chat');
    await tester.enterText(find.byKey(const Key('composer')), 'New input');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await network();
    for (var i = 0;
        i < 30 && controller.streamingText == null && controller.error == null;
        i++) {
      await network();
    }
    expect(controller.streamingText, 'Official controlled text',
        reason:
            '${controller.error} ${controller.currentRun?.data} ${controller.outbox.length}\n$errors');
    await tester.pump();
    await tester.pump();
    expect(find.text('Official controlled text'), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('composer')), 'Guide at checkpoint');
    await tester.pump();
    for (var i = 0; i < 40 && !controller.canGuideRun; i++) {
      await network();
    }
    expect(controller.canGuideRun, isTrue,
        reason:
            '${controller.error} ${controller.currentRun?.snapshot.data}\n$errors');
    await tester.pump();
    await tester.tap(find.byTooltip('Guide current work'));
    await network();
    for (var i = 0; i < 20 && controller.runPending; i++) {
      await network();
    }
    expect(controller.runPending, isFalse,
        reason:
            '${controller.error} ${controller.currentRun?.snapshot.data}\n$errors');
    expect(controller.current!.messages.map((m) => m.content), [
      'External context',
      'Existing reply',
      'New input',
      'Official controlled final response'
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Official controlled final response'), findsOneWidget);
    expect(jsonDecode(controller.currentRun!.payload),
        {'input': 'New input', 'session_id': 'external_chat'});
    await tester.runAsync(() async {
      final core = await controller.coreFor(controller.connections.single);
      try {
        final history =
            await core.loadRemoteHistory('controlled', 'external_chat');
        expect(history.sessionId, 'external_chat');
        expect(history.messages.map((m) => m['content']), [
          'External context',
          'Existing reply',
          'New input',
          'Official controlled final response'
        ]);
      } finally {
        core.close();
      }
    });
    // HTTP and widget continuations use both real I/O and the test scheduler.
    // Drain the active request before disposing its ChatHome owner.
    for (var i = 0;
        i < 12 && (controller.busy || controller.controlBusy);
        i++) {
      await network();
    }
    expect(controller.busy || controller.controlBusy, isFalse,
        reason:
            'Controlled status/control requests must settle before teardown');
    await tester.pumpWidget(const SizedBox());
  });
}
