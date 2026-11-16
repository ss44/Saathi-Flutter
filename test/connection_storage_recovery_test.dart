import 'dart:async';
import 'dart:convert';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

const fixture = <String, dynamic>{
  'id': 'fixture',
  'name': 'Fixture',
  'type': 'openai',
  'url': 'https://example.test'
};

class DelayedSecrets extends MemorySecrets {
  Completer<void>? delay;
  bool failWrite = false;
  @override
  Future<void> write(String id, String value) async {
    await delay?.future;
    if (failWrite) throw StateError('fixture failure');
    await super.write(id, value);
  }
}

class FailingPreferences extends InMemorySharedPreferencesStore {
  FailingPreferences() : super.empty();
  int failures = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (failures > 0) {
      failures--;
      return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'delayed add rejects store and controller overlap and disposal never publishes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = DelayedSecrets();
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(), secrets: secrets);
    final c = ChatController(store);
    await c.load();
    secrets.delay = Completer<void>();
    final pending = c.addConnection(fixture, 'fixture-key');
    await expectLater(
        c.addConnection({...fixture, 'id': 'second'}, ''), throwsStateError);
    await expectLater(
        store.saveConnection({...fixture, 'id': 'second'}, apiKey: ''),
        throwsStateError);
    c.dispose();
    secrets.delay!.complete();
    await pending;
    expect(c.connections, isEmpty);
    expect((await store.load()).connections.single['id'], 'fixture');
  });
  test('failed secret write restores metadata and old key', () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = DelayedSecrets();
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(), secrets: secrets);
    await store.saveConnection(fixture, apiKey: 'fixture-old-key');
    secrets.failWrite = true;
    await expectLater(
        store.changeConnection('fixture',
            replacement: {...fixture, 'name': 'Changed'},
            apiKey: 'fixture-new-key'),
        throwsA(isA<StorageRecoveryException>()));
    expect((await store.load()).connections.single['name'], 'Fixture');
    expect(await secrets.read('fixture'), 'fixture-old-key');
  });
  test(
      'failed preferences compensation still restores secret and controller fails closed',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecrets();
    final store = SaathiStore(preferences: prefs, secrets: secrets);
    final c = ChatController(store);
    await c.load();
    await c.addConnection(fixture, 'fixture-old-key');
    await c.newSession(fixture, 'fixture-model', '');
    final platform = FailingPreferences()..failures = 2;
    SharedPreferencesStorePlatform.instance = platform;
    await expectLater(
        c.updateConnection('fixture', {...fixture, 'name': 'Changed'},
            apiKey: 'fixture-new-key'),
        throwsA(isA<StorageRecoveryException>()));
    expect(await secrets.read('fixture'), 'fixture-old-key');
    expect(c.connections.single['name'], 'Fixture');
    expect(c.readOnly, isTrue);
    expect(c.canChangeConnections, isFalse);
    expect(await c.send('fixture blocked'), isFalse);
    await expectLater(
        c.addConnection({...fixture, 'id': 'second'}, ''), throwsStateError);
    expect(c.error, contains('recovery'));
    expect(jsonEncode((await store.load()).connections),
        isNot(contains('fixture-old-key')));
    c.dispose();
  });
}
