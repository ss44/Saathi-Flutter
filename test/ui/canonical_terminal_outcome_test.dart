import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../review64_terminal_failure_test.dart'
    show CleanupSecrets, OutcomeHost;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final outcome in ['completed', 'failed', 'cancelled']) {
    for (final cleanupFailure in [false, true]) {
      for (final selectBeforeSettlement in [false, true]) {
        test(
            '$outcome nonanswer preserves original feedback cleanup=$cleanupFailure otherSelected=$selectBeforeSettlement',
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
            'url': host.url,
          }, '');
          await c.connectCanonical(c.connections.single, host.invite);
          await c.attachCanonical(GatewaySession({'session_id': 'chat'}));
          final original = c.current!;
          final owner = c.canonical!;
          final other = ChatSession(
              id: 'other', connectionId: 'different-source', model: 'other');
          c.sessions.add(other);
          var alerts = 0;
          c.onReplyReceived = (_) => alerts++;
          expect(await c.send('first'), isTrue);
          expect(c.runPending, isTrue);
          expect(owner.client.run!.state, GatewayRunState.running);
          expect(c.error, isNull);
          host.history = [
            {
              'row_id': 3,
              'role': 'user',
              'content': 'first',
              'display_metadata': {'submission_id': host.inputId},
            },
            {'row_id': 4, 'role': 'assistant', 'content': ' \n '},
            {
              'row_id': 5,
              'role': 'tool',
              'name': 'lookup',
              'content': 'private tool body'
            },
            {
              'row_id': 6,
              'role': 'assistant',
              'row_kind': 'compaction',
              'content': 'Context compacted'
            },
          ];
          // A blank/tool-only snapshot while genuinely running is not a final.
          await c.refreshCanonical();
          expect(c.error, isNull);
          expect(c.runPending, isTrue);
          if (selectBeforeSettlement) c.select(other);
          host.terminal = true;
          secrets.failDelete = cleanupFailure;
          await c.refreshCanonical();
          final requests = host.requests.length;
          if (cleanupFailure) {
            expect(c.unsavedChanges, isTrue);
            expect(c.error, contains('Could not resync or save'));
            await c.retrySave();
            expect(c.unsavedChanges, isTrue);
            expect(c.error, contains('Could not resync or save'));
            secrets.failDelete = false;
            await c.retrySave();
            expect(host.requests.length, requests);
          }
          expect(c.unsavedChanges, isFalse);
          expect(owner.pending, isFalse);
          expect(owner.awaitingSnapshotSave, isFalse);
          expect(
              owner.client.run!.state,
              switch (outcome) {
                'failed' => GatewayRunState.failed,
                'cancelled' => GatewayRunState.cancelled,
                _ => GatewayRunState.complete,
              });
          if (selectBeforeSettlement) {
            expect(c.current, same(other));
            expect(c.error, isNull);
            expect(other.messages, isEmpty);
            c.select(original);
          }
          final expected = switch (outcome) {
            'failed' =>
              'The server could not complete this response. Nothing will be resent.',
            'cancelled' =>
              'This response was cancelled. Nothing will be resent.',
            _ =>
              'The server finished without a text response. Nothing will be resent.',
          };
          expect(c.error, expected);
          expect(c.runPending, isFalse);
          expect(original.messages, hasLength(4));
          expect(
              original.messages
                  .every((m) => m.metadata['authoritativeCompletion'] != true),
              isTrue);
          final entry = c.organization.entry(c.identityOf(original));
          expect(entry.unread, isFalse);
          expect(entry.completions, isEmpty);
          expect(alerts, 0);
          // A later resync and selection cannot erase the settled outcome.
          await c.refreshCanonical();
          expect(c.error, expected);
          c.select(other);
          expect(c.error, isNull);
          c.select(original);
          expect(c.error, expected);
          expect(alerts, 0);
          expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
              hasLength(1));
        });
      }
    }
  }
}
