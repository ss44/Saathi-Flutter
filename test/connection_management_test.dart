import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

class FailingSecrets extends MemorySecrets {
  bool fail = false;
  @override
  Future<void> delete(String id) async {
    if (fail) throw StateError('Synthetic secure storage failure');
    await super.delete(id);
  }
}

void main() {
  test('add rejects while busy and rename retains optional metadata', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await c.load();
    final v = <String, dynamic>{
      'id': 'safe',
      'name': 'Safe',
      'url': 'https://example.test',
      'type': 'openai',
      'model': 'fixture-model',
      'systemPrompt': 'fixture-prompt',
      'allowInsecureHttp': false
    };
    c.busy = true;
    await expectLater(c.addConnection(v, 'fixture-key'), throwsStateError);
    c.busy = false;
    await c.addConnection(v, 'fixture-key');
    await c.updateConnection(
        'safe', {'name': 'Renamed', 'url': v['url'], 'type': v['type']});
    expect((await c.store.load()).connections.single['model'], 'fixture-model');
    expect(c.connections.single['systemPrompt'], 'fixture-prompt');
    c.dispose();
  });
  test('failed secure deletion retains metadata and busy mutation rejects',
      () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = FailingSecrets();
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(), secrets: secrets);
    final c = ChatController(store);
    await c.load();
    final connection = <String, dynamic>{
      'id': 'fixture',
      'name': 'Fixture',
      'url': 'https://example.test',
      'type': 'openai'
    };
    await c.addConnection(connection, 'synthetic-key');
    c.busy = true;
    await expectLater(c.deleteConnection('fixture'), throwsStateError);
    await expectLater(
        c.updateConnection('fixture', connection), throwsStateError);
    c.busy = false;
    secrets.fail = true;
    await expectLater(c.deleteConnection('fixture'), throwsStateError);
    expect(c.connections, hasLength(1));
    expect((await store.load()).connections, hasLength(1));
    expect(await secrets.read('fixture'), 'synthetic-key');
    expect(c.changingConnection, isFalse);
    c.dispose();
  });

  test(
      'rename preserves secret, endpoint revision isolates history, delete rejects stale IDs',
      () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = MemorySecrets();
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(), secrets: secrets);
    final c = ChatController(store);
    await c.load();
    final original = <String, dynamic>{
      'id': 'fixture',
      'name': 'Fixture',
      'type': 'openai',
      'url': 'https://example.test'
    };
    await c.addConnection(original, 'synthetic-secret');
    await c.newSession(original, 'fixture-model', '');
    await c.updateConnection('fixture', {...original, 'name': 'Renamed'});
    expect(await secrets.read('fixture'), 'synthetic-secret');
    await c.updateConnection('fixture', {...original, 'name': 'Renamed'},
        apiKey: '');
    expect(await secrets.read('fixture'), isNull);
    await c.updateConnection(
        'fixture', {...original, 'url': 'https://other.test'});
    expect(c.connections.single['id'], isNot('fixture'));
    expect(c.current!.connectionId, 'fixture');
    expect(await secrets.read('fixture'), isNull);
    expect(await c.send('must not send'), isFalse);
    await expectLater(c.newSession(original, 'model', ''), throwsStateError);
    await expectLater(c.deleteConnection('fixture'), throwsStateError);
    final id = c.connections.single['id'] as String;
    await c.deleteConnection(id);
    expect(c.connections, isEmpty);
    expect(c.sessions, hasLength(1));
    expect(await secrets.read(id), isNull);
    c.dispose();
  });
}
