import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'hermes_gateway_test.dart' show Fixture, snapshot;
import 'independent_security_review_test.dart' show TlsFixture;

class TransactionSecrets extends MemorySecrets {
  String? fifo;
  Completer<void>? entered, release;
  bool failWrite = false, failDelete = false;
  bool gateJournalRead = false;

  @override
  Future<String?> read(String id) async {
    final value = await super.read(id);
    if (gateJournalRead && id.startsWith('gateway.journal.')) {
      gateJournalRead = false;
      entered!.complete();
      await release!.future;
    }
    return value;
  }

  @override
  Future<void> write(String id, String value) async {
    // Deliberately mutate the backing before returning an error. Rollback must
    // repair the actual record, not merely retain an in-memory candidate.
    await super.write(id, value);
    if (id.startsWith('gateway.fifo.')) {
      fifo = id;
      if (failWrite) {
        failWrite = false;
        entered?.complete();
        if (release != null) await release!.future;
        throw StateError('controlled ambiguous FIFO write failure');
      }
    }
  }

  @override
  Future<void> delete(String id) async {
    await super.delete(id);
    if (failDelete && id.startsWith('gateway.journal.')) {
      failDelete = false;
      throw StateError('controlled ambiguous journal delete failure');
    }
  }
}

Map<String, Object> held(String id) => {
      'inputId': id,
      'text': 'accepted $id',
      'sessionId': 'chat',
      'profileId': 'profile',
      'state': 'prepared',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
      'overlapping failed cancel and append drain before recreation without losing A',
      () async {
    SharedPreferences.setMockInitialValues({});
    final f = TlsFixture();
    await f.start();
    final secrets = TransactionSecrets();
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(), secrets: secrets);
    final c = ChatController(store);
    ChatController? replacement;
    addTearDown(() async {
      c.dispose();
      replacement?.dispose();
      await f.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'type': 'hermesGateway',
      'name': 'native',
      'url': f.url
    }, '');
    final sessions = await c.connectCanonical(c.connections.single, f.invite());
    await c.attachCanonical(sessions.single);
    final owner = c.canonical!;
    expect(c.submit('accepted A'), isTrue);
    expect(c.submit('accepted B'), isTrue);
    while (c.canonicalQueueSaving) {
      await Future<void>.delayed(Duration.zero);
    }
    final a = c.outbox.first;
    final b = c.outbox.last;
    secrets.entered = Completer<void>();
    secrets.release = Completer<void>();
    secrets.failWrite = true;
    final cancel = c.cancelQueued(a);
    await secrets.entered!.future;
    // The public owner accepts another durable follower while controller
    // cancellation is waiting; the paused composer itself remains unchanged.
    final append = owner.queueInput('C', 'accepted C');
    expect(c.outbox.map((i) => i.text), ['accepted A', 'accepted B']);
    secrets.release!.complete();
    await cancel;
    await append;
    while (c.canonicalQueueSaving) {
      await Future<void>.delayed(Duration.zero);
    }
    await c.cancelQueued(b);
    expect(c.outbox.map((i) => i.text), ['accepted A']);
    expect(owner.queuedInputs.map((i) => i.text), ['accepted A', 'accepted C']);
    final raw = (jsonDecode((await secrets.read(secrets.fifo!))!) as List);
    expect(raw.map((i) => i['text']), ['accepted A', 'accepted C']);
    c.dispose();
    replacement = ChatController(store);
    await replacement.load();
    final rows = await replacement.connectCanonical(
        replacement.connections.single, f.invite());
    await replacement.attachCanonical(rows.single);
    expect(replacement.outbox.map((i) => i.text), ['accepted A', 'accepted C']);
    expect(f.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });

  test('accepted overlapping writes drain after close before replacement reads',
      () async {
    final f = Fixture();
    await f.start();
    f.respond = (_) => snapshot();
    final secrets = TransactionSecrets();
    CanonicalChat make() => CanonicalChat(
        HermesGatewayClient(grantProvider: () async => f.grant()), secrets,
        source: 'source', isCurrent: () => true);
    final owner = make();
    final replacement = make();
    addTearDown(() async {
      await owner.close();
      await replacement.close();
      await f.close();
    });
    await owner.connect();
    await owner.attach('chat');
    await owner.queueInput('A', 'accepted A');
    await owner.queueInput('B', 'accepted B');
    secrets.entered = Completer<void>();
    secrets.release = Completer<void>();
    secrets.failWrite = true;
    final failed = expectLater(owner.removeQueuedInput('A'), throwsStateError);
    await secrets.entered!.future;
    final cancelB = owner.removeQueuedInput('B');
    final append = owner.queueInput('C', 'accepted C');
    await owner.close();
    await replacement.connect();
    var attached = false;
    final handoff = replacement.attach('chat').then((_) {
      attached = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(attached, isFalse);
    secrets.release!.complete();
    await failed;
    await cancelB;
    await append;
    await handoff;
    expect(replacement.queuedInputs.map((i) => i.id), ['A', 'C']);
    expect(
        (jsonDecode((await secrets.read(secrets.fifo!))!) as List)
            .map((r) => r['id']),
        ['A', 'C']);
    expect(() => owner.removeQueuedInput('A'), throwsStateError);
    expect(f.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });

  test(
      'prepared cancellation rolls back both FIFO and journal on delete failure',
      () async {
    final f = Fixture();
    await f.start();
    f.respond = (_) => snapshot();
    final secrets = TransactionSecrets();
    const key = 'gateway.journal.source.chat';
    final prior = jsonEncode(held('A'));
    await secrets.write(key, prior);
    final owner = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => f.grant()), secrets,
        source: 'source', isCurrent: () => true);
    addTearDown(() async {
      await owner.close();
      await f.close();
    });
    await owner.connect();
    await owner.attach('chat');
    await owner.queueInput('A', 'accepted A');
    await owner.queueInput('B', 'accepted B');
    secrets.failDelete = true;
    await expectLater(owner.removeQueuedInput('A'), throwsStateError);
    await owner.removeQueuedInput('B');
    expect(owner.queuedInputs.map((i) => i.id), ['A']);
    expect(owner.heldInputId, 'A');
    expect(await secrets.read(key), prior);
    expect(
        (jsonDecode((await secrets.read(secrets.fifo!))!) as List)
            .map((r) => r['id']),
        ['A']);
    expect(f.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });

  test(
      'held delete reservation serializes read/delete against same-key handoff',
      () async {
    final f = Fixture();
    await f.start();
    f.respond = (r) => r['method'] == 'session.resume'
        ? snapshot()
        : {
            'admission_id': 'replacement-run',
            'ref': {'profile_id': 'profile', 'session_id': 'chat'},
            'authority_epoch': 3,
            'execution_generation': 4,
            'status': 'started',
          };
    final secrets = TransactionSecrets();
    await secrets.write('gateway.journal.source.chat', jsonEncode(held('old')));
    CanonicalChat make() => CanonicalChat(
        HermesGatewayClient(grantProvider: () async => f.grant()), secrets,
        source: 'source', isCurrent: () => true);
    final old = make();
    final replacement = make();
    addTearDown(() async {
      await old.close();
      await replacement.close();
      await f.close();
    });
    await old.connect();
    await old.attach('chat');
    secrets.entered = Completer<void>();
    secrets.release = Completer<void>();
    secrets.gateJournalRead = true;
    final discard = old.discardHeldInput('old');
    await secrets.entered!.future;
    await old.close();
    await replacement.connect();
    var attached = false;
    final handoff = replacement.attach('chat').then((_) {
      attached = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(attached, isFalse);
    secrets.release!.complete();
    expect(await discard, isTrue);
    await handoff;
    await replacement.send('replacement', inputId: 'new');
    expect(await old.discardHeldInput('old'), isFalse);
    expect(await secrets.read('gateway.journal.source.chat'),
        contains('replacement-run'));
  });

  test(
      'same input ID with different stored admission is not held-delete authority',
      () async {
    final f = Fixture();
    await f.start();
    f.respond = (_) => snapshot();
    final secrets = TransactionSecrets();
    const key = 'gateway.journal.source.chat';
    await secrets.write(key, jsonEncode(held('A')));
    final owner = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => f.grant()), secrets,
        source: 'source', isCurrent: () => true);
    addTearDown(() async {
      await owner.close();
      await f.close();
    });
    await owner.connect();
    await owner.attach('chat');
    final replacement =
        jsonEncode({...held('A'), 'state': 'admitted', 'admissionId': 'other'});
    await secrets.write(key, replacement);
    expect(await owner.discardHeldInput('A'), isFalse);
    expect(await secrets.read(key), replacement);
  });

  test(
      'unknown journal head survives cancellation and followers across restart',
      () async {
    final f = Fixture();
    await f.start();
    f.respond = (_) => snapshot();
    final secrets = TransactionSecrets();
    const key = 'gateway.journal.source.chat';
    final raw = jsonEncode({...held('A'), 'state': 'uncertain'});
    await secrets.write(key, raw);
    CanonicalChat make() => CanonicalChat(
        HermesGatewayClient(grantProvider: () async => f.grant()), secrets,
        source: 'source', isCurrent: () => true);
    final owner = make();
    final replacement = make();
    addTearDown(() async {
      await owner.close();
      await replacement.close();
      await f.close();
    });
    await owner.connect();
    await owner.attach('chat');
    await owner.queueInput('A', 'accepted A');
    await owner.queueInput('B', 'accepted B');
    expect(() => owner.removeQueuedInput('A'), throwsStateError);
    await owner.removeQueuedInput('B');
    await owner.close();
    await replacement.connect();
    await replacement.attach('chat');
    expect(replacement.pendingInputId, 'A');
    expect(replacement.queuedInputs.single.id, 'A');
    expect(await secrets.read(key), raw);
    expect(f.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });
}
