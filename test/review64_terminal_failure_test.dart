import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'gateway/canonical_combined_controller_test.dart' show NativeHost;

class OutcomeHost extends NativeHost {
  OutcomeHost(this.outcome);
  final String outcome;
  @override
  Map<String, dynamic> receipt() => {
        ...super.receipt(),
        if (terminal) 'outcome': outcome,
      };
}

class CleanupSecrets extends MemorySecrets {
  bool failDelete = false;
  @override
  Future<void> delete(String id) async {
    if (failDelete && id.startsWith('gateway.journal.')) {
      throw StateError('controlled journal cleanup failure');
    }
    await super.delete(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final outcome in ['completed', 'failed', 'cancelled']) {
    for (final failCleanup in [false, true]) {
      test(
          'empty canonical $outcome cleanupFailure=$failCleanup retains outcome',
          () async {
        final host = OutcomeHost(outcome);
        await host.start();
        SharedPreferences.setMockInitialValues({});
        final secrets = CleanupSecrets();
        final c = ChatController(SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: secrets));
        addTearDown(() async {
          c.dispose();
          await host.close();
        });
        await c.load();
        await c.addConnection({
          'id': 'native',
          'name': 'Native',
          'type': 'hermesGateway',
          'url': host.url
        }, '');
        await c.connectCanonical(c.connections.single, host.invite);
        await c.attachCanonical(GatewaySession({'session_id': 'chat'}));
        var alerts = 0;
        c.onReplyReceived = (_) => alerts++;
        expect(await c.send('first'), isTrue);
        host.history = [
          {
            'row_id': 3,
            'role': 'user',
            'content': 'first',
            'display_metadata': {'submission_id': host.inputId}
          },
          {'row_id': 4, 'role': 'assistant', 'content': ' \n '},
        ];
        host.terminal = true;
        secrets.failDelete = failCleanup;
        await c.refreshCanonical();
        if (failCleanup) {
          expect(c.unsavedChanges, isTrue);
          final requests = host.requests.length;
          await c.retrySave();
          expect(c.unsavedChanges, isTrue);
          secrets.failDelete = false;
          await c.retrySave();
          expect(host.requests.length, requests);
          expect(c.unsavedChanges, isFalse);
        }
        expect(
            c.canonical!.client.run!.state,
            switch (outcome) {
              'failed' => GatewayRunState.failed,
              'cancelled' => GatewayRunState.cancelled,
              _ => GatewayRunState.complete,
            });
        expect(c.runPending, isFalse);
        expect(alerts, 0);
        expect(c.organization.entry(c.identityOf(c.current!)).unread, isFalse);
        expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
            hasLength(1));
        expect(c.error ?? c.canonical!.problem, isNotNull,
            reason:
                'A failed/cancelled/empty terminal must remain explicit after persistence, not Attached to Hermes only');
        final original = c.current!;
        final other =
            ChatSession(id: 'other', connectionId: 'native', model: 'other');
        c.sessions.add(other);
        c.select(other);
        expect(c.error, isNull);
        c.select(original);
        expect(c.error, isNotNull);
      });
    }
  }
}
