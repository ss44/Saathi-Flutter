import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../pending_message_home_test.dart' show FlowFixture;
import 'hermes_catalog_flow_test.dart' show capabilities;

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool used = false;
  Future<void> wait() async {
    if (used) return;
    used = true;
    entered.complete();
    await release.future;
  }
}

class _Secrets extends MemorySecrets {
  final String boundary;
  final _Gate gate;
  bool armed = false;
  int credentialReads = 0;
  final freshPermission = _Gate();
  _Secrets(this.boundary, this.gate);
  @override
  Future<String?> read(String id) async {
    if (armed && id == 'source') {
      credentialReads++;
      if (credentialReads == 2) await freshPermission.wait();
      if (boundary == 'secret' && credentialReads == 1) await gate.wait();
    }
    return super.read(id);
  }

  @override
  Future<void> write(String id, String value) async {
    if (armed && boundary == 'native prepared' && id.startsWith('run.v1.')) {
      await gate.wait();
    }
    await super.write(id, value);
  }
}

const _channel = MethodChannel('plugins.flutter.io/shared_preferences');
Future<void> _flush(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 10));
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  }
}

void _background(WidgetTester t) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused
  ]) {
    t.binding.handleAppLifecycleStateChanged(state);
  }
}

void _foreground(WidgetTester t) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed
  ]) {
    t.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets(
      'already-admitted zero-follower work resumes observation, not submission',
      (t) async {
    final f = FlowFixture();
    await f.mount(t);
    f.admission.complete();
    await t.runAsync(() => f.c.send('Owned native head'));
    final operation = f.c.currentRun!;
    final reads = f.reads;
    expect(operation.runId, 'original');
    expect(f.c.outbox, isEmpty);
    _background(t);
    await t.pump(const Duration(seconds: 10));
    expect(f.reads, reads);
    _foreground(t);
    await t.pump(const Duration(seconds: 2));
    await _flush(t);
    expect(f.reads, greaterThan(reads));
    expect(f.c.currentRun, same(operation));
    expect(f.posts, 1);
    expect(f.c.showPendingThinking, isTrue);
    f.status = 'completed';
    await t.pump(const Duration(seconds: 2));
    await _flush(t);
    expect(f.c.runPending, isFalse);
    expect(f.c.showPendingThinking, isFalse);
    expect(f.c.current!.messages.last.content, 'Final answer');
    expect(f.posts, 1);
    await f.close(t);
  });
  for (final native in [false, true]) {
    for (final boundary in native
        ? ['secret', 'discovery', 'native prepared']
        : ['secret', 'prepared', 'dispatched']) {
      for (final revocation in ['lifecycle', 'explicit pause', 'selection']) {
        for (final releaseBeforeReturn in [false, true]) {
          testWidgets(
              '${native ? 'Runs' : 'direct'} $boundary revokes old permission and validates fresh authority after $revocation; release-before-return=$releaseBeforeReturn',
              (t) async {
            final gate = _Gate();
            final secrets = _Secrets(boundary, gate);
            final disk = <String, Object>{};
            final requests = <http.Request>[];
            SharedPreferences.resetStatic();
            SharedPreferencesStorePlatform.instance =
                MethodChannelSharedPreferencesStore();
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(_channel, (call) async {
              final args = call.arguments as Map?;
              if (call.method == 'getAll') {
                return Map<String, Object>.from(disk);
              }
              if (call.method.startsWith('set')) {
                if (args!['key'] ==
                        'flutter.${ChatController.preparedInputsKey}' &&
                    (args['value'] as String).contains('"state":"$boundary"')) {
                  await gate.wait();
                }
                disk[args['key'] as String] = args['value'] as Object;
              } else if (call.method == 'remove') {
                disk.remove(args!['key']);
              }
              return true;
            });
            final client = MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('capabilities')) {
                if (boundary == 'discovery') await gate.wait();
                return http.Response(jsonEncode(capabilities), 200);
              }
              if (request.method == 'POST') {
                return http.Response(
                    native
                        ? '{"run_id":"owned","status":"started"}'
                        : '{"choices":[{"message":{"content":"Only head answer"}}]}',
                    native ? 202 : 200);
              }
              return http.Response(
                  '{"run_id":"owned","status":"completed","output":"Only head answer"}',
                  200);
            });
            late ChatController c;
            await t.runAsync(() async {
              c = ChatController(
                  SaathiStore(
                      preferences: await SharedPreferences.getInstance(),
                      secrets: secrets),
                  coreFactory: () => SaathiCore(client: client),
                  runClientFactory: (root, key) =>
                      RunClient(root, key, client: client));
              await c.load();
              await c.addConnection({
                'id': 'source',
                'name': 'Original',
                'type': native ? 'hermes' : 'openai',
                'url': 'https://original.example'
              }, 'fixture-secret');
              await c.newSession(c.connections.single, 'original-model',
                  'Original instructions',
                  upstreamProvider: native ? 'original-provider' : null);
            });
            t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
            final original = c.current!;
            final source = c.connections.single;
            secrets.armed = true;
            expect(c.submit('Only accepted head'), isTrue);
            await _flush(t);
            expect(gate.entered.isCompleted, isTrue);
            expect(c.outbox, isEmpty,
                reason: 'No follower masks popped-head revocation');
            final before = requests.length;
            Map<String, dynamic>? preparedBefore;
            if (!native) {
              preparedBefore = Map<String, dynamic>.from((jsonDecode(c
                      .store.preferences
                      .getString(ChatController.preparedInputsKey)!) as List)
                  .single as Map)
                ..remove('state');
            }
            if (revocation != 'selection') {
              _background(t);
              if (revocation == 'explicit pause') c.pauseQueue('Paused by you');
            } else {
              final other = ChatSession(
                  id: 'other', connectionId: 'source', model: 'other-model');
              c.sessions.add(other);
              c.select(other);
            }
            if (releaseBeforeReturn) {
              gate.release.complete();
              await _flush(t);
            }
            if (revocation != 'selection') {
              _foreground(t);
            } else {
              c.select(original);
            }
            if (!releaseBeforeReturn) gate.release.complete();
            await _flush(t);
            try {
              expect(requests, hasLength(before),
                  reason: 'No new HTTP after one-way revocation');
              expect(requests.where((r) => r.method == 'POST'), isEmpty);
              expect(c.current, same(original));
              expect(c.connections.single, same(source));
              expect(c.uncertainInput, isNull);
              expect(original.messages, isEmpty);
              Future<void>? recovery;
              if (boundary == 'native prepared') {
                expect(c.busy, isFalse);
                final op = c.currentRun!;
                expect(op.data['attempted'], isNot(true));
                expect(op.runId, isNull);
                expect(c.pendingText, 'Only accepted head');
                final retained = await t
                    .runAsync(() => secrets.read('run.v1.${original.id}'));
                expect(retained, isNotNull);
                expect(c.outbox, isEmpty,
                    reason: 'The prepared ledger owns the only head');
                // Existing durable prepared-operation recovery retains its key;
                // it must not create a second queue head or bypass fresh authority.
                recovery = c.checkRunStatus();
                await _flush(t);
                expect(c.currentRun, same(op));
                expect(
                    await t
                        .runAsync(() => secrets.read('run.v1.${original.id}')),
                    retained);
              } else if (revocation != 'lifecycle') {
                expect(c.busy, isFalse);
                expect(secrets.freshPermission.entered.isCompleted, isFalse);
                expect(c.outbox.single.text, 'Only accepted head');
                expect(c.outbox.single.connection, same(source));
                expect(c.queueStatus, isNotNull);
                if (revocation == 'explicit pause') {
                  expect(c.queueStatus, 'Paused by you');
                }
                expect(c.canResumeQueue, isTrue);
                c.resumeQueue();
                await _flush(t);
              }
              // Ordinary foreground return reaches this gate WITHOUT Resume.
              // Reviving the old permission would POST before a second read;
              // requiring Resume would never reach this new permission at all.
              expect(secrets.freshPermission.entered.isCompleted, isTrue);
              expect(secrets.credentialReads, 2);
              expect(requests, hasLength(before));
              if (!native) {
                final restored = Map<String, dynamic>.from((jsonDecode(c
                        .store.preferences
                        .getString(ChatController.preparedInputsKey)!) as List)
                    .single as Map)
                  ..remove('state');
                expect(restored, preparedBefore);
              }
              secrets.freshPermission.release.complete();
              await _flush(t);
              expect(c.busy, isFalse);
              if (recovery != null) await recovery;
              final post = requests.where((r) => r.method == 'POST').single;
              expect(post.url.host, 'original.example');
              expect(post.headers['authorization'], 'Bearer fixture-secret');
              final body = jsonDecode(post.body) as Map;
              expect(body['model'], 'original-model');
              if (native) {
                expect(body['provider'], 'original-provider');
                expect(body['input'], 'Only accepted head');
                expect(body['instructions'], 'Original instructions');
                expect(post.body, c.currentRun!.payload);
                expect(post.headers['Idempotency-Key'], c.currentRun!.key);
              } else {
                expect(body['messages'], [
                  {'role': 'system', 'content': 'Original instructions'},
                  {'role': 'user', 'content': 'Only accepted head'}
                ]);
              }
              expect(original.messages.map((m) => m.content),
                  ['Only accepted head', 'Only head answer']);
              expect(c.outbox, isEmpty);
              expect(c.uncertainInput, isNull);
              expect(t.takeException(), isNull);
            } finally {
              await t.pumpWidget(const SizedBox());
              c.dispose();
              client.close();
              await t.pump();
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(_channel, null);
              SharedPreferences.setMockInitialValues({});
            }
          });
        }
      }
    }
  }
}
