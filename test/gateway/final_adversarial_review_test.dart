import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'independent_security_review_test.dart' show TlsFixture;
import 'hermes_gateway_test.dart' show Fixture, snapshot;
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/gateway/hermes_gateway.dart';

class FailFifoSecrets extends MemorySecrets {
  bool failNext = false;
  final saved = <String, String>{};
  @override
  Future<void> write(String id, String value) async {
    if (id.startsWith('gateway.fifo.') && failNext) {
      failNext = false;
      throw StateError('controlled failed FIFO write');
    }
    await super.write(id, value);
    saved[id] = value;
  }
}

void main() {
  test('stale disposed held owner cannot erase replacement admitted journal',
      () async {
    final f = Fixture();
    await f.start();
    f.respond = (r) => r['method'] == 'session.resume'
        ? snapshot()
        : {
            'admission_id': 'new-run',
            'ref': {'profile_id': 'profile', 'session_id': 'chat'},
            'authority_epoch': 3,
            'execution_generation': 4,
            'status': 'started'
          };
    final secrets = MemorySecrets();
    const key = 'gateway.journal.source.chat';
    await secrets.write(
        key,
        jsonEncode({
          'inputId': 'old',
          'text': 'old held',
          'sessionId': 'chat',
          'profileId': 'profile',
          'state': 'prepared'
        }));
    CanonicalChat make() => CanonicalChat(
        HermesGatewayClient(grantProvider: () async => f.grant()), secrets,
        source: 'source', isCurrent: () => true);
    final old = make();
    await old.connect();
    await old.attach('chat');
    await old.close();
    final fresh = make();
    await fresh.connect();
    await fresh.attach('chat');
    await fresh.discardHeldInput('old');
    await fresh.send('new accepted work', inputId: 'new');
    final before = await secrets.read(key);
    final staleAccepted = await old.discardHeldInput('old');
    final after = await secrets.read(key);
    stdout.writeln(
        'STALE_JOURNAL_REPRO accepted=$staleAccepted before=$before after=$after freshPending=${fresh.pending}');
    await fresh.close();
    final restarted = make();
    await restarted.connect();
    await restarted.attach('chat');
    stdout.writeln('STALE_JOURNAL_RECREATED_PENDING=${restarted.pending}');
    await restarted.close();
    await f.close();
    expect(staleAccepted, isFalse);
    expect(after, before);
  });
  test(
      'failed cancellation cannot erase another accepted input on later successful cancellation',
      () async {
    SharedPreferences.setMockInitialValues({});
    final f = TlsFixture();
    await f.start();
    final secrets = FailFifoSecrets();
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(), secrets: secrets));
    addTearDown(() async {
      c.dispose();
      await f.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'type': 'hermesGateway',
      'name': 'native',
      'url': f.url
    }, '');
    final rows = await c.connectCanonical(c.connections.single, f.invite());
    await c.attachCanonical(rows.first);
    final owner = c.canonical!;
    // The fixture advertises a pending approval, so accepted followers stay held.
    expect(c.submit('accepted A'), isTrue);
    expect(c.submit('accepted B'), isTrue);
    while (c.canonicalQueueSaving) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final a = c.outbox[0], b = c.outbox[1];
    secrets.failNext = true;
    await c.cancelQueued(a);
    expect(c.outbox.map((i) => i.text), ['accepted A', 'accepted B']);
    await c.cancelQueued(b);
    final raw = secrets.saved.entries
        .singleWhere((e) => e.key.startsWith('gateway.fifo.'))
        .value;
    stdout.writeln(
        'CANCEL_REPRO UI=${c.outbox.map((i) => i.text).toList()} OWNER=${owner.queuedInputs.map((i) => i.text).toList()} STORED=$raw');
    final store = c.store;
    c.dispose();
    final recreated = ChatController(store);
    await recreated.load();
    final again = await recreated.connectCanonical(
        recreated.connections.single, f.invite());
    await recreated.attachCanonical(again.first);
    stdout.writeln(
        'CANCEL_RECREATED=${recreated.outbox.map((i) => i.text).toList()}');
    recreated.dispose();
    expect((jsonDecode(raw) as List).map((i) => i['text']), ['accepted A']);
  });
  test('disposed owner cannot initiate durable queue cancellation', () async {
    SharedPreferences.setMockInitialValues({});
    final f = TlsFixture();
    await f.start();
    final secrets = FailFifoSecrets();
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(), secrets: secrets));
    await c.load();
    await c.addConnection({
      'id': 'native',
      'type': 'hermesGateway',
      'name': 'native',
      'url': f.url
    }, '');
    final rows = await c.connectCanonical(c.connections.single, f.invite());
    await c.attachCanonical(rows.first);
    final owner = c.canonical!;
    await owner.queueInput('a', 'accepted A');
    await owner.close();
    Object? error;
    try {
      await owner.removeQueuedInput('a');
    } catch (e) {
      error = e;
    }
    final raw = secrets.saved.entries
        .singleWhere((e) => e.key.startsWith('gateway.fifo.'))
        .value;
    stdout.writeln('CLOSED_REPRO error=$error STORED=$raw');
    c.dispose();
    await f.close();
    expect(error, isNotNull);
    expect((jsonDecode(raw) as List).length, 1);
  });
}
