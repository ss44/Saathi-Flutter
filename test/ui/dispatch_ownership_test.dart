import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

class DelayedSecrets extends MemorySecrets {
  Completer<String?>? pending;
  @override
  Future<String?> read(String id) => pending?.future ?? super.read(id);
}

void main() {
  late ChatController c;
  late DelayedSecrets secrets;
  late List<String> requests;
  late List<Completer<http.Response>> replies;
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 20));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets = DelayedSecrets();
    requests = [];
    replies = [];
    c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: secrets),
        coreFactory: () => SaathiCore(client: MockClient((r) {
              requests.add(r.body);
              final reply = Completer<http.Response>();
              replies.add(reply);
              return reply.future;
            })));
    await c.load();
    final connection = {
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'https://example.com'
    };
    await c.addConnection(connection, '');
    await c.newSession(connection, 'small', '');
  });
  tearDown(() => c.dispose());

  for (final action in [
    'switch away/back',
    'explicit pause',
    'background return'
  ]) {
    test('preparing head is held without HTTP after $action', () async {
      final original = c.current!;
      secrets.pending = Completer<String?>();
      expect(c.submit('Original accepted text'), isTrue);
      expect(c.outbox, isEmpty,
          reason: 'Preparing head is not a cancellable follower');
      if (action == 'switch away/back') {
        final other =
            ChatSession(id: 'other', connectionId: 'a', model: 'small');
        c.sessions.add(other);
        c.select(other);
        c.select(original);
      } else if (action == 'explicit pause') {
        c.pauseQueue('Explicit pause');
      } else {
        c.setQueueBackground(true);
        c.setQueueBackground(false);
      }
      secrets.pending!.complete('');
      await tick();
      expect(requests, isEmpty);
      expect(c.uncertainInput, isNull);
      expect(c.outbox.single.text, 'Original accepted text');
      expect(c.queueStatus, isNotNull);
      expect(original.messages, isEmpty);
      expect(c.canResumeQueue, isTrue);
      await c.cancelQueued(c.outbox.single);
      expect(c.outbox, isEmpty);
      expect(c.queueStatus, isNull);
    });
  }

  testWidgets('owner ChatHome-only disposal revokes preparing head', (t) async {
    final visible = ValueNotifier<bool>(true);
    await t.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (_, show, child) => show
          ? ChatHome(controller: c)
          : const Scaffold(body: Text('Retained app')),
    )));
    secrets.pending = Completer<String?>();
    expect(c.submit('Original accepted text'), isTrue);
    await t.pump();
    visible.value = false;
    await t.pump();
    expect(find.text('Retained app'), findsOneWidget);
    secrets.pending!.complete('');
    await t.runAsync(tick);
    await t.pump();
    expect(requests, isEmpty);
    expect(c.uncertainInput, isNull);
    expect(c.outbox.single.text, 'Original accepted text');
    expect(c.queueStatus, isNotNull);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    visible.dispose();
  });

  test('completion listener cannot steal drain ownership or lose follower',
      () async {
    bool? publicSendResult;
    var attempted = false;
    c.addListener(() {
      if (!c.busy && !attempted) {
        attempted = true;
        unawaited(c
            .send('B must be refused')
            .then((result) => publicSendResult = result));
        expect(c.submit('C follower'), isTrue);
      }
    });
    c.submit('A');
    await tick();
    replies[0].complete(
        http.Response('{"choices":[{"message":{"content":"Done A"}}]}', 200));
    await tick();
    expect(publicSendResult, isFalse);
    expect(requests.length, 2);
    expect(requests.last, contains('C follower'));
    expect(requests.last, isNot(contains('B must be refused')));
    expect(c.uncertainInput, isNull);
    expect(c.pendingText, 'C follower');
    replies[1].complete(
        http.Response('{"choices":[{"message":{"content":"Done C"}}]}', 200));
    await tick();
    expect(requests.length, 2);
    expect(c.current!.messages.map((m) => m.content),
        ['A', 'Done A', 'C follower', 'Done C']);
    expect(c.outbox, isEmpty);
    expect(c.uncertainInput, isNull);
  });
}
