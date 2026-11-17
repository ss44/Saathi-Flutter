import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

class RealHttp extends HttpOverrides {}

class ControlledSaveController extends ChatController {
  ControlledSaveController(super.store);
  bool failNextSave = false;
  @override
  Future<void> persist() async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('Controlled history failure after native completion');
    }
    await super.persist();
  }
}

/// Explicit controlled OFFICIAL canonical gateway, not part of hermetic CI.
void main() {
  testWidgets(
      'official canonical WSS host invite drawer resume prompt same-session result',
      (tester) => HttpOverrides.runWithHttpOverrides(() async {
            late Directory root;
            late Process server;
            late ControlledSaveController c;
            late Map<String, dynamic> ready;
            final errors = StringBuffer();
            final initialized = await tester.runAsync<bool>(() async {
              root = await Directory('.dart_tool').createTemp('canonical-');
              addTearDown(() async {
                await root.delete(recursive: true);
              });
              final cert = '${root.path}/cert.pem',
                  key = '${root.path}/key.pem';
              final tls = await Process.run('openssl', [
                'req',
                '-x509',
                '-newkey',
                'rsa:2048',
                '-nodes',
                '-keyout',
                key,
                '-out',
                cert,
                '-days',
                '1',
                '-subj',
                '/CN=localhost',
                '-addext',
                'subjectAltName=DNS:localhost,IP:127.0.0.1'
              ]);
              expect(tls.exitCode, 0);
              SecurityContext.defaultContext.setTrustedCertificates(cert);
              server = await Process.start(
                  Platform.environment['HERMES_TEST_PYTHON'] ??
                      '/opt/hermes/.venv/bin/python',
                  [
                    'tool/hermes_canonical_server.py',
                    '--source',
                    Platform.environment['HERMES_TEST_SOURCE'] ?? '/opt/hermes',
                    '--home',
                    '${root.path}/home',
                    '--cert',
                    cert,
                    '--key',
                    key
                  ]);
              addTearDown(() async {
                server.kill();
                await server.exitCode.timeout(const Duration(seconds: 5),
                    onTimeout: () {
                  server.kill(ProcessSignal.sigkill);
                  return server.exitCode;
                });
              });
              server.stderr.transform(utf8.decoder).listen((line) {
                errors.write(line);
                if (line.contains('canonical-stage')) {
                  stdout.writeln(line.trim());
                }
              });
              final lines = server.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .asBroadcastStream();
              ready = Map<String, dynamic>.from(jsonDecode(await lines
                      .firstWhere((s) => s.startsWith('{'))
                      .timeout(const Duration(seconds: 180),
                          onTimeout: () =>
                              throw StateError('Canonical startup: $errors')))
                  as Map);
              SharedPreferences.setMockInitialValues({});
              c = ControlledSaveController(SaathiStore(
                  preferences: await SharedPreferences.getInstance(),
                  secrets: MemorySecrets()));
              addTearDown(c.dispose);
              await c.load();
              return true;
            });
            stdout.writeln('official-ui checkpoint initialized');
            if (initialized != true) return;
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
            Future<void> settle() async {
              for (var i = 0; i < 12; i++) {
                await tester.pump(const Duration(milliseconds: 30));
                await tester.runAsync(() =>
                    Future<void>.delayed(const Duration(milliseconds: 30)));
              }
            }

            await tester.tap(find.byTooltip('Open navigation menu'));
            await settle();
            await tester.tap(find.text('Hermes Desktop / CLI'));
            await settle();
            await tester.enterText(find.byKey(const Key('gateway-trusted-url')),
                ready['url'] as String);
            final invite = await tester.runAsync(
                () => File(ready['invitePath'] as String).readAsString());
            await tester.enterText(
                find.widgetWithText(TextField, 'Host-issued invite JSON'),
                invite!);
            await tester
                .ensureVisible(find.text('Trust this host and connect'));
            // Allocate real socket/ping timers outside Flutter's fake clock.
            await tester.runAsync(
                () => tester.tap(find.text('Trust this host and connect')));
            await settle();
            for (var i = 0;
                i < 30 &&
                    find.text('Canonical external session').evaluate().isEmpty;
                i++) {
              await settle();
            }
            stdout.writeln('official-ui checkpoint listed');
            expect(find.text('Canonical external session'), findsOneWidget,
                reason:
                    '$errors UI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(" | ")}');
            await tester.ensureVisible(find.text('Canonical external session'));
            await tester.tap(find.text('Canonical external session'));
            await settle();
            for (var i = 0;
                i < 40 && (c.current == null || c.current!.messages.isEmpty);
                i++) {
              await settle();
            }
            expect(c.current, isNotNull,
                reason:
                    'Attach did not settle: $errors UI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(" | ")}');
            stdout.writeln('official-ui checkpoint attached-or-result');
            expect(c.current!.remoteSessionId, ready['sessionId']);
            expect(
                c.current!.messages
                    .any((m) => m.content == 'External Desktop context'),
                isTrue);
            await settle();
            final composer = find.byKey(const Key('composer'));
            expect(tester.widget<TextField>(composer).enabled, isTrue);
            await tester.enterText(composer, 'New canonical input');
            await tester.pump();
            expect(tester.widget<TextField>(composer).controller!.text,
                'New canonical input');
            // Existing composer and FIFO, not a parallel chat screen.
            expect(c.readOnly, isFalse,
                reason:
                    'Native source must remain authorized after explicit attachment');
            expect(c.runPending, isFalse);
            await tester.tap(find.byTooltip('Send'));
            await settle();
            for (var i = 0;
                i < 20 &&
                    find.text('Canonical stub streaming').evaluate().isEmpty;
                i++) {
              await settle();
            }
            stdout.writeln('official-ui checkpoint stream');
            expect(find.text('Canonical stub streaming'), findsOneWidget);
            expect(c.runPending, isTrue);
            await tester.enterText(composer, 'Guide the actual canonical turn');
            await tester.pump();
            expect(c.canonical!.canControl, isTrue,
                reason:
                    'connected=${c.canonical!.connected} needsAction=${c.canonical!.needsUserAction} state=${c.canonical!.client.run?.state} generation=${c.canonical!.client.run?.executionGeneration} snapshotGeneration=${c.canonical!.snapshot?.executionGeneration}');
            await tester.tap(find.byTooltip('Use draft while Hermes works'));
            await settle();
            await tester.tap(find.text('Guide current work'));
            await settle();
            expect(tester.widget<TextField>(composer).controller!.text, isEmpty,
                reason:
                    'Only a verified native control ACK may consume the draft');
            expect(c.canonical!.problem, contains('Guidance accepted'));
            expect(c.runPending, isTrue);
            await tester.enterText(composer, 'Retained canonical draft');
            stdout.writeln('official-ui checkpoint guided');
            c.failNextSave = true;
            server.stdin.writeln('finish');
            await tester.runAsync(() => server.stdin.flush());
            for (var i = 0;
                i < 30 &&
                    !c.current!.messages
                        .any((m) => m.content == 'Canonical stub final answer');
                i++) {
              await settle();
            }
            stdout.writeln('official-ui checkpoint attached-or-result');
            expect(c.current!.remoteSessionId, ready['sessionId']);
            expect(
                c.current!.messages
                    .where((m) => m.content == 'New canonical input'),
                hasLength(1),
                reason:
                    'error=${c.error} outbox=${c.outbox.length} pending=${c.runPending} native=${c.canonical?.problem} connection=${c.canonical?.client.state} messages=${c.current!.messages.map((m) => m.content).toList()} host=$errors');
            expect(
                c.current!.messages
                    .where((m) => m.content == 'Canonical stub final answer'),
                hasLength(1),
                reason:
                    '$errors UI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(" | ")}');
            expect(c.unsavedChanges, isTrue,
                reason:
                    'A native final must stay held on failed history persistence');
            expect(c.runPending, isTrue);
            final beforeSaveRetry = c.canonical!.client.attached;
            stdout.writeln('official-ui checkpoint before-storage-retry');
            // Secure FIFO/history writes can have continuations on the widget
            // clock as well as real socket callbacks. Drive both schedulers;
            // awaiting runAsync alone strands a valid fake-clock continuation.
            late Future<void> saving;
            var saved = false;
            await tester.runAsync(() async {
              saving = c.retrySave().then((_) {
                saved = true;
              });
            });
            for (var i = 0; i < 20 && !saved; i++) {
              await settle();
            }
            expect(saved, isTrue,
                reason:
                    'Storage-only retry must settle with both schedulers driven');
            await tester
                .runAsync(() => saving.timeout(const Duration(seconds: 5)));
            await settle();
            stdout.writeln('official-ui checkpoint after-storage-retry');
            expect(c.canonical!.client.attached, same(beforeSaveRetry),
                reason:
                    'Try saving again is storage-only, not another native read or prompt');
            expect(c.unsavedChanges, isFalse);
            expect(c.runPending, isFalse);
            expect(tester.widget<TextField>(composer).controller!.text,
                'Retained canonical draft');
            await tester.runAsync(() async {
              await c.refreshCanonical();
            });
            expect(
                c.current!.messages
                    .where((m) => m.content == 'Canonical stub final answer'),
                hasLength(1));
            stdout.writeln('official-ui checkpoint external');
            server.stdin.writeln('external');
            await tester.runAsync(() => server.stdin.flush());
            for (var i = 0;
                i < 30 &&
                    !c.current!.messages
                        .any((m) => m.content == 'External client followup');
                i++) {
              await settle();
            }
            stdout.writeln('official-ui checkpoint attached-or-result');
            expect(c.current!.remoteSessionId, ready['sessionId']);
            expect(
                c.current!.messages
                    .where((m) => m.content == 'External client followup'),
                hasLength(1),
                reason:
                    'external resync: error=${c.error} native=${c.canonical?.problem} observable=${c.canonical?.observable} messages=${c.current!.messages.map((m) => m.content).toList()} host=$errors');
            expect(
                c.current!.messages
                    .where((m) => m.content == 'Canonical stub final answer'),
                hasLength(2));
            expect(c.streamingText, isNull);
            expect(tester.widget<TextField>(composer).controller!.text,
                'Retained canonical draft');
            final original = c.current!;
            final other = ChatSession(
                id: 'other',
                connectionId: original.connectionId,
                model: 'Hermes');
            c.sessions.add(other);
            c.select(other);
            server.stdin.writeln('hold');
            stdout.writeln('official-ui checkpoint external');
            server.stdin.writeln('external');
            await tester.runAsync(() => server.stdin.flush());
            await settle();
            server.stdin.writeln('finish');
            await tester.runAsync(() => server.stdin.flush());
            for (var i = 0;
                i < 30 &&
                    original.messages
                            .where((m) =>
                                m.content == 'Canonical stub final answer')
                            .length <
                        3;
                i++) {
              await settle();
            }
            expect(c.current, same(other));
            expect(other.messages, isEmpty);
            expect(
                original.messages
                    .where((m) => m.content == 'Canonical stub final answer'),
                hasLength(3),
                reason:
                    'A completion must save into A while B remains selected: ${c.error} $errors');
            c.select(original);
            expect(c.canonical!.connected, isFalse,
                reason: 'A→B→A must not revive the old selection lease');
            stdout.writeln('official-ui checkpoint unmount');
            await tester.pumpWidget(const SizedBox());
            await settle();
          }, RealHttp()),
      timeout: const Timeout(Duration(minutes: 4)));
}
