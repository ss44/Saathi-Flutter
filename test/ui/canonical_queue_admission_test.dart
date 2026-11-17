import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../gateway/canonical_combined_controller_test.dart' as fixture;

class _RejectingQueue extends CanonicalChat {
  _RejectingQueue(SecretStore secrets)
      : super(
            HermesGatewayClient(
                grantProvider: () => throw StateError('no dial')),
            secrets,
            source: 'native',
            isCurrent: () => true);
  int attempts = 0;
  @override
  bool get connected => true;
  @override
  Future<void> queueInput(String id, String text) {
    attempts++;
    throw StateError('synchronous admission rejection');
  }

  @override
  Future<void> removeQueuedInput(String id) async {}
}

class _QueueController extends ChatController {
  _QueueController(super.store, this.owner);
  final CanonicalChat owner;
  @override
  CanonicalChat? get canonical => owner;
}

class _RealHttp extends HttpOverrides {}

void main() {
  test('synchronous native admission rejection always releases saving state',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final owner = _RejectingQueue(store.secrets);
    final c = _QueueController(store, owner);
    addTearDown(() async {
      c.dispose();
      await owner.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'name': 'Native',
      'type': 'hermesGateway',
      'url': 'wss://example.test'
    }, '');
    await c.newSession(c.connections.single, 'native', '');
    expect(c.submit('x' * (ChatController.maxInputLength + 1)), isFalse);
    expect(owner.attempts, 0);
    expect(c.outbox, isEmpty);
    expect(c.canonicalQueueSaving, isFalse);
    expect(c.submit('retain this rejected input'), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(owner.attempts, 1);
    expect(c.canonicalQueueSaving, isFalse);
    expect(c.unsavedChanges, isTrue);
    expect(c.outbox.single.text, 'retain this rejected input');
    expect(c.queueStatus, contains('held'));
    await c.cancelQueued(c.outbox.single);
    expect(c.outbox, isEmpty);
  });

  testWidgets(
      'ordinary native Stop keeps followers held through terminal resync',
      (t) => HttpOverrides.runWithHttpOverrides(() async {
            late ChatController c;
            late fixture.NativeHost host;
            await t.runAsync(() async {
              final setup = await fixture.setup();
              c = setup.$1;
              host = setup.$2;
            });
            t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
            await t.runAsync(() async {
              await c.send('first');
              expect(c.submit('held follower'), isTrue);
              await Future<void>.delayed(const Duration(milliseconds: 30));
            });
            await t.pump();
            await t.tap(find.byTooltip('Stop current Hermes work'));
            await t.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 30)));
            expect(c.queueStatus, contains('Stopped'));
            await t.runAsync(() async {
              host.terminal = true;
              await c.refreshCanonical();
              await Future<void>.delayed(const Duration(milliseconds: 30));
            });
            expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                hasLength(1));
            expect(c.outbox.single.text, 'held follower');
            expect(c.canResumeQueue, isTrue);
            await t.runAsync(() async {
              c.resumeQueue();
              await Future<void>.delayed(const Duration(milliseconds: 30));
            });
            expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                hasLength(2));
            await t.runAsync(() => c.canonical!.close());
            await t.pumpWidget(const SizedBox());
          }, _RealHttp()));
}
