import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'controller_failure_test.dart' show FailingStore;

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 20));
void main() {
  late ChatController c;
  late FailingStore store;
  late List<Completer<http.Response>> replies;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = FailingStore(await SharedPreferences.getInstance());
    replies = [];
    c = ChatController(store,
        coreFactory: () => SaathiCore(client: MockClient((_) {
              final r = Completer<http.Response>();
              replies.add(r);
              return r.future;
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
  void complete(int i, {bool fail = false}) =>
      replies[i].complete(http.Response(
          fail ? '{}' : '{"choices":[{"message":{"content":"Done"}}]}',
          fail ? 500 : 200));
  for (final cancelFollower in [false, true]) {
    test('legacy unknown survives empty outbox (cancel=$cancelFollower)',
        () async {
      final source = c.current!;
      final active = c.send('Unknown legacy');
      if (cancelFollower) {
        expect(c.submit('Cancel follower'), isTrue);
        await c.cancelQueued(c.outbox.single);
      }
      await tick();
      complete(0, fail: true);
      expect(await active, isFalse);
      expect(c.uncertainInput?.text, 'Unknown legacy');
      expect(c.queueStatus, isNotNull);
      expect(c.submit('No retry'), isFalse);
      expect(await c.send('No bypass'), isFalse);
      c.resumeQueue();
      await tick();
      expect(replies.length, 1);
      await c.abandonHeldOutbox(source);
      expect(c.uncertainInput, isNull);
      expect(c.queueStatus, isNull);
    });
  }
  test('direct send cannot bypass an unsaved response', () async {
    final first = c.send('First');
    await tick();
    store.fail = true;
    complete(0);
    expect(await first, isTrue);
    expect(c.unsavedChanges, isTrue);
    final bypass = c.send('Bypass');
    await tick();
    expect(replies.length, 1);
    expect(await bypass, isFalse);
  });
  test('direct send cannot bypass paused FIFO followers', () async {
    c.submit('First');
    c.submit('Held second');
    await tick();
    c.pauseQueue('Explicit pause');
    complete(0);
    await tick();
    final bypass = c.send('Bypass');
    await tick();
    expect(replies.length, 1);
    expect(await bypass, isFalse);
    expect(c.outbox.single.text, 'Held second');
    expect(c.queueStatus, 'Explicit pause');
    c.resumeQueue();
    await tick();
    expect(replies.length, 2);
    complete(1);
    await tick();
  });
  test('direct send cannot overtake ready FIFO followers', () async {
    final first = c.send('First');
    c.submit('Second');
    Future<bool>? bypass;
    c.addListener(() {
      if (!c.busy && c.outbox.isNotEmpty && bypass == null) {
        bypass = c.send('Overtake');
      }
    });
    await tick();
    complete(0);
    expect(await first, isTrue);
    await tick();
    expect(await bypass, isFalse);
    expect(c.pendingText, 'Second');
    complete(1);
    await tick();
  });
  test('legacy awaited send also drains explicitly submitted followups',
      () async {
    final active = c.send('First');
    expect(c.submit('Second'), isTrue);
    await tick();
    complete(0);
    expect(await active, isTrue);
    await tick();
    expect(replies.length, 2);
    complete(1);
    await tick();
  });
  test(
      'switch away and back requires explicit resume; cancel never cancels active',
      () async {
    c.submit('First');
    c.submit('Cancel me');
    c.submit('Third');
    await c.cancelQueued(c.outbox.first);
    // This case covers an already dispatched active request. Preparation-time
    // revocation is covered separately with delayed credentials.
    await tick();
    expect(replies.length, 1);
    final original = c.current!;
    c.select(ChatSession(id: 'other', connectionId: 'a', model: 'small'));
    c.select(original);
    await tick();
    complete(0);
    await tick();
    expect(replies.length, 1);
    expect(c.queueStatus, isNotNull);
    c.resumeQueue();
    await tick();
    expect(replies.length, 2);
    complete(1);
    await tick();
  });
  test('storage failure pauses until durable save and explicit resume',
      () async {
    c.submit('First');
    c.submit('Second');
    store.fail = true;
    await tick();
    complete(0);
    await tick();
    expect(replies.length, 1);
    expect(c.unsavedChanges, isTrue);
    c.resumeQueue();
    await tick();
    expect(replies.length, 1);
    store.fail = false;
    await c.retrySave();
    await tick();
    expect(replies.length, 1);
    c.resumeQueue();
    await tick();
    expect(replies.length, 2);
    complete(1);
    await tick();
  });
  test('uncertain failure keeps input and forbids automatic or explicit retry',
      () async {
    c.submit('Keep this');
    c.submit('Second');
    await tick();
    complete(0, fail: true);
    await tick();
    expect(c.uncertainInput?.text, 'Keep this');
    expect(c.outbox.single.text, 'Second');
    c.resumeQueue();
    await tick();
    expect(replies.length, 1);
  });
  test('unknown outcome is local and returning cannot retry or drain followers',
      () async {
    final original = c.current!;
    c.submit('Unknown');
    c.submit('Held');
    await tick();
    complete(0, fail: true);
    await tick();
    await c.newSession(c.connections.single, 'small', '');
    expect(c.queueStatus, isNull);
    expect(c.uncertainInput, isNull);
    expect(c.outbox, isEmpty);
    expect(c.submit('Independent'), isTrue);
    await tick();
    expect(replies.length, 2);
    complete(1);
    await tick();
    c.select(original);
    expect(c.uncertainInput?.text, 'Unknown');
    expect(c.submit('Must not send'), isFalse);
    c.resumeQueue();
    await tick();
    expect(replies.length, 2);
    expect(c.outbox.single.text, 'Held');
  });
  test('background after final item leaves no stale pause blocking fresh input',
      () async {
    c.submit('First');
    await tick();
    c.setQueueBackground(true);
    complete(0);
    await tick();
    c.setQueueBackground(false);
    expect(c.queueStatus, isNull);
    expect(c.submit('Fresh'), isTrue);
    await tick();
    complete(1);
    await tick();
  });
  test('dispose before credential read completes never dispatches', () async {
    c.submit('First');
    c.dispose();
    await tick();
    expect(replies, isEmpty);
  });
  test('background return requires explicit resume', () async {
    c.submit('First');
    c.submit('Second');
    await tick();
    c.setQueueBackground(true);
    await tick();
    complete(0);
    await tick();
    c.setQueueBackground(false);
    await tick();
    expect(replies.length, 1);
    c.resumeQueue();
    await tick();
    expect(replies.length, 2);
    complete(1);
    await tick();
  });
  test('deleted source is read-only and never drains held followers', () async {
    c.submit('First');
    c.submit('Held');
    await tick();
    c.setQueueBackground(true);
    complete(0);
    await tick();
    c.setQueueBackground(false);
    await c.deleteConnection('a');
    expect(c.readOnly, isTrue);
    expect(c.submit('No'), isFalse);
    c.resumeQueue();
    await tick();
    expect(replies.length, 1);
    expect(c.outbox.single.text, 'Held');
  });
  test('actual credential replacement cannot resume original-source followers',
      () async {
    c.submit('First');
    c.submit('Held');
    await tick();
    c.setQueueBackground(true);
    complete(0);
    await tick();
    c.setQueueBackground(false);
    await c.updateConnection('a', {...c.connections.single},
        apiKey: 'replacement');
    expect(c.canResumeQueue, isFalse);
    c.resumeQueue();
    await tick();
    expect(replies.length, 1);
    expect(c.outbox.single.text, 'Held');
  });
  test('cancel one follower preserves others and unknown outcome', () async {
    c.submit('Unknown');
    c.submit('Cancel only this');
    c.submit('Keep');
    await tick();
    complete(0, fail: true);
    await tick();
    await c.cancelQueued(c.outbox.first);
    expect(c.outbox.single.text, 'Keep');
    expect(c.uncertainInput?.text, 'Unknown');
    expect(c.queueStatus, isNotNull);
  });
  test('independent selected queue drains after another chat becomes unknown',
      () async {
    final first = c.current!;
    await c.newSession(c.connections.single, 'small', '');
    final second = c.current!;
    c.select(first);
    expect(c.submit('Unknown A'), isTrue);
    expect(c.submit('Held A'), isTrue);
    await tick();
    c.select(second);
    expect(c.submit('Independent B'), isTrue);
    complete(0, fail: true);
    await tick();
    expect(replies.length, 2,
        reason:
            'Accepted input in an independent chat must not become stranded');
    complete(1);
    await tick();
    c.select(first);
    expect(c.uncertainInput?.text, 'Unknown A');
    expect(c.outbox.single.text, 'Held A');
    expect(c.canResumeQueue, isFalse);
    expect(replies.length, 2);
  });
  test('pausing selected chat does not replace another chat pause', () async {
    final first = c.current!;
    await c.newSession(c.connections.single, 'small', '');
    final second = c.current!;
    c.select(first);
    c.submit('First A');
    c.submit('Held A');
    await tick();
    c.select(second);
    c.submit('Held B');
    c.pauseQueue('Only B');
    // Inspect the other chat without select() introducing another pause.
    c.current = first;
    expect(c.queueStatus, isNot('Only B'));
    complete(0);
    await tick();
    expect(replies.length, 1);
  });
  test('malformed history blocks queue without requests or overwriting data',
      () async {
    c.dispose();
    const malformed = '{broken saved history';
    await store.preferences.setString('saathi.chats.v1', malformed);
    var observedHttpInvocations = 0;
    c = ChatController(store,
        coreFactory: () => SaathiCore(client: MockClient((_) async {
              observedHttpInvocations++;
              return http.Response('{}', 500);
            })));
    await c.load();
    expect(c.readOnly, isTrue);
    expect(c.submit('Must stay local'), isFalse);
    expect(await c.send('Must also stay local'), isFalse);
    await tick();
    expect(observedHttpInvocations, 0);
    expect(c.outbox, isEmpty);
    expect(replies, isEmpty);
    expect(store.preferences.getString('saathi.chats.v1'), malformed);
  });
  test('replacement map with same ID never reroutes queued input', () async {
    c.submit('First');
    c.submit('Second');
    await tick();
    c.connections[0] = {...c.connections[0]};
    complete(0);
    await tick();
    expect(replies.length, 1);
    expect(c.canResumeQueue, isFalse);
  });
}
