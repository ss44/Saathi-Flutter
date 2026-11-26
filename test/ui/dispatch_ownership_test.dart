import 'dart:async';
import 'dart:convert';
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
  Completer<String?>? pending, fresh;
  int gatedReads = 0;
  @override
  Future<String?> read(String id) {
    if (pending == null) return super.read(id);
    gatedReads++;
    return (gatedReads == 1 ? pending! : fresh ?? pending!).future;
  }
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

  for (final action in ['switch away/back', 'explicit pause']) {
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
      } else {
        c.pauseQueue('Explicit pause');
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

  test(
      'background return rejects old permission then reauthorizes unsent head once',
      () async {
    final original = c.current!;
    final source = c.connections.single;
    secrets.pending = Completer<String?>();
    secrets.fresh = Completer<String?>();
    expect(c.submit('Original accepted text'), isTrue);
    await tick();
    expect(secrets.gatedReads, 1);
    expect(c.outbox, isEmpty);
    final prepared =
        c.store.preferences.getString(ChatController.preparedInputsKey);
    expect(prepared, isNotNull);
    c.setQueueBackground(true);
    c.setQueueBackground(false);
    secrets.pending!.complete('');
    await tick();
    // The aggregate-zero-POST assertion after return hid the permission boundary:
    // automatic continuation is allowed, but only under a NEW validated grant.
    expect(requests, isEmpty,
        reason: 'The revoked credential read cannot send');
    expect(secrets.gatedReads, 2,
        reason:
            'Foreground continuation obtains fresh authority without Resume');
    expect(c.store.preferences.getString(ChatController.preparedInputsKey),
        prepared);
    expect(c.uncertainInput, isNull);
    expect(original.messages, isEmpty);
    expect(c.connections.single, same(source));
    secrets.fresh!.complete('');
    await tick();
    expect(requests, hasLength(1));
    expect(jsonDecode(requests.single), {
      'model': 'small',
      'stream': true,
      'stream_options': {'include_usage': true},
      'messages': [
        {'role': 'user', 'content': 'Original accepted text'}
      ]
    });
    replies.single.complete(
        http.Response('{"choices":[{"message":{"content":"Done"}}]}', 200));
    await tick();
    expect(original.messages.map((m) => m.content),
        ['Original accepted text', 'Done']);
    expect(c.outbox, isEmpty);
    expect(c.uncertainInput, isNull);
    expect(requests, hasLength(1));
  });

  test(
      'source replacement round trip cannot reauthorize a background-held head',
      () async {
    final originalSource = c.connections.single;
    secrets.pending = Completer<String?>();
    expect(c.submit('Original accepted text'), isTrue);
    await tick();
    c.setQueueBackground(true);
    secrets.pending!.complete('');
    await tick();
    expect(c.busy, isFalse);
    expect(requests, isEmpty);
    expect(c.outbox.single.connection, same(originalSource));
    secrets.pending = null;
    await c.updateConnection('a', {...originalSource},
        apiKey: 'fixture-replacement');
    await c.updateConnection('a', {...originalSource}, apiKey: '');
    expect(c.connections.single, isNot(same(originalSource)));
    c.setQueueBackground(false);
    await tick();
    expect(c.canResumeQueue, isFalse);
    c.resumeQueue();
    await tick();
    expect(requests, isEmpty);
    expect(c.outbox.single.text, 'Original accepted text');
    expect(c.outbox.single.connection, same(originalSource));
    expect(c.uncertainInput, isNull);
    expect(c.current!.messages, isEmpty);
  });

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
