import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'gateway/canonical_combined_controller_test.dart' as native;

class FailingHistory extends SaathiStore {
  FailingHistory({required super.preferences, required super.secrets});
  bool fail = false;
  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    if (fail) throw StateError('controlled storage failure');
    await super.saveChats(chats);
  }
}

class RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'canonical empty terminal must retain truthful feedback',
      (t) => HttpOverrides.runWithHttpOverrides(() async {
            late ChatController c;
            await t.runAsync(() async {
              final setup = await native.setup();
              c = setup.$1;
              final host = setup.$2;
              expect(await c.send('first'), isTrue);
              host.history = [
                {'row_id': 1, 'role': 'user', 'content': 'Earlier input'},
                {'row_id': 2, 'role': 'assistant', 'content': 'Earlier reply'},
                {
                  'row_id': 3,
                  'role': 'user',
                  'content': 'first',
                  'display_metadata': {'submission_id': host.inputId}
                },
                {'row_id': 4, 'role': 'assistant', 'content': ' \n '},
              ];
              host.terminal = true;
              await c.refreshCanonical();
              expect(c.current!.messages, hasLength(4));
              expect(c.runPending, isFalse);
              expect(c.current!.messages.last.content, ' \n ');
              expect(
                  c.current!.messages.last.metadata['authoritativeCompletion'],
                  isNull);
              expect(c.organization.entry(c.identityOf(c.current!)).unread,
                  isFalse);
              expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                  hasLength(1));
            });
            // Apply foreground state after real async setup, before mounting the owner.
            t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
            await t.pumpAndSettle();
            expect(find.byType(MessageView), findsNWidgets(3));
            expect(find.text('Attached to Hermes'), findsOneWidget);
            expect(
                find.textContaining('without a text response'), findsOneWidget,
                reason:
                    'A newly completed empty answer cannot silently disappear');
            await t.runAsync(() => c.canonical!.client.disconnect());
            await t.pumpWidget(const SizedBox.shrink());
            await t.pumpAndSettle();
          }, RealHttp()));

  testWidgets('empty direct answer storage retry must retain feedback',
      (t) async {
    late ChatController c;
    var requests = 0;
    var alerts = 0;
    await t.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final store = FailingHistory(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets());
      c = ChatController(store,
          coreFactory: () => SaathiCore(client: MockClient((_) async {
                requests++;
                return http.Response(
                    jsonEncode({
                      'choices': [
                        {
                          'message': {'content': '  '}
                        }
                      ]
                    }),
                    200);
              })));
      await c.load();
      await c.addConnection({
        'id': 'd',
        'name': 'Direct',
        'type': 'openai',
        'url': 'https://example.com'
      }, '');
      await c.newSession(c.connections.single, 'small', '');
      c.onReplyReceived = (_) => alerts++;
      store.fail = true;
      expect(await c.send('Question'), isTrue);
      expect(c.unsavedChanges, isTrue);
      expect(c.error, contains('not saved'));
      expect(await c.send('must not repeat'), isFalse);
      await c.retrySave();
      expect(c.unsavedChanges, isTrue);
      expect(c.error, contains('still not saved'));
      store.fail = false;
      await c.retrySave();
      expect(c.unsavedChanges, isFalse);
      expect(c.current!.messages, hasLength(2));
      expect(c.current!.messages.last.content, '  ');
      expect(
          c.current!.messages.last.metadata['authoritativeCompletion'], isNull);
      expect(c.organization.entry(c.identityOf(c.current!)).unread, isFalse);
      expect(requests, 1);
      expect(alerts, 0,
          reason: 'An empty answer is not a completed reply alert');
    });
    addTearDown(c.dispose);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    expect(find.byType(MessageView), findsOneWidget);
    expect(find.textContaining('without a text response'), findsOneWidget,
        reason: 'Storage retry should not erase the empty-final outcome');
    final original = c.current!;
    await t.runAsync(() => c.newSession(c.connections.single, 'small', ''));
    expect(c.error, isNull);
    c.select(original);
    expect(c.error, contains('without a text response'));
    expect(requests, 1);
    await t.pumpAndSettle();
  });

  test(
      'canonical empty outcome survives failed snapshot save and storage-only retry',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final (previous, host, secrets) = await native.setup();
            previous.dispose();
            final store = FailingHistory(
                preferences: await SharedPreferences.getInstance(),
                secrets: secrets);
            final c = ChatController(store);
            addTearDown(c.dispose);
            await c.load();
            await c.connectCanonical(c.connections.single, host.invite);
            await c.attachCanonical(
                GatewaySession({'session_id': 'chat', 'title': 'Native A'}));
            expect(await c.send('first'), isTrue);
            host.history = [
              {'row_id': 1, 'role': 'user', 'content': 'Earlier input'},
              {'row_id': 2, 'role': 'assistant', 'content': 'Earlier reply'},
              {
                'row_id': 3,
                'role': 'user',
                'content': 'first',
                'display_metadata': {'submission_id': host.inputId}
              },
              {
                'row_id': 4,
                'role': 'tool',
                'name': 'lookup',
                'content': 'private tool body'
              },
              {'row_id': 5, 'role': 'assistant', 'content': ' \n '},
            ];
            host.terminal = true;
            store.fail = true;
            await c.refreshCanonical();
            expect(c.unsavedChanges, isTrue);
            expect(c.runPending, isTrue);
            expect(await c.send('must not repeat'), isFalse);
            final records = c.current!.messages.map((m) => m.toJson()).toList();
            final requests = host.requests.length;
            store.fail = false;
            await c.retrySave();
            expect(host.requests.length, requests,
                reason: 'Retry saves the captured snapshot only');
            expect(c.unsavedChanges, isFalse);
            expect(c.runPending, isFalse);
            expect(
                c.current!.messages.map((m) => m.toJson()).toList(), records);
            expect(c.current!.messages[3].id, 'canonical-chat-4');
            expect(c.current!.messages[3].metadata['canonicalRowKind'],
                'toolActivity');
            expect(
                c.organization.entry(c.identityOf(c.current!)).unread, isFalse);
            expect(c.error, contains('without a text response'));
            await c.refreshCanonical();
            expect(c.error, contains('without a text response'));
            expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                hasLength(1));
          }, RealHttp()));

  test(
      'canonical historical and active blank rows are not empty-final outcomes',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final (c, host, _) = await native.setup();
            host.history = [
              {'row_id': 1, 'role': 'user', 'content': 'Earlier input'},
              {'row_id': 2, 'role': 'assistant', 'content': ' \n '},
            ];
            await c.refreshCanonical();
            expect(c.error, isNull);
            expect(await c.send('first'), isTrue);
            host.history!.addAll([
              {
                'row_id': 3,
                'role': 'user',
                'content': 'first',
                'display_metadata': {'submission_id': host.inputId}
              },
              {'row_id': 4, 'role': 'assistant', 'content': ' \n '},
            ]);
            await c.refreshCanonical();
            expect(c.runPending, isTrue);
            expect(c.error, isNull);
            host.history!.add({
              'row_id': 5,
              'role': 'assistant',
              'content': 'Actual final answer'
            });
            host.terminal = true;
            await c.refreshCanonical();
            expect(c.runPending, isFalse);
            expect(c.error, isNull);
            expect(c.current!.messages.last.metadata['authoritativeCompletion'],
                isTrue);
            expect(
                c.organization.entry(c.identityOf(c.current!)).unread, isTrue);
            expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                hasLength(1));
          }, RealHttp()));
}
