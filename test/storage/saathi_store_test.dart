import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';

class FailedChatPreferences implements SharedPreferences {
  final Map<String, Object> values = {};
  bool fail = false;
  bool throwOnFailure = false;
  @override
  String? getString(String key) => values[key] as String?;
  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    if (fail && throwOnFailure) throw StateError('Controlled write failure');
    return !fail;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return !fail;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PausedSecrets extends MemorySecrets {
  Completer<void>? written;
  Completer<void>? release;
  @override
  Future<void> write(String id, String value) async {
    await super.write(id, value);
    written?.complete();
    await release?.future;
  }
}

void main() {
  test(
      'legacy credential migration rotates, clears, and deletes selected slots',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecrets();
    final store = SaathiStore(preferences: prefs, secrets: secrets);
    await store.saveConnection({'id': 'a'}, apiKey: 'old-fixture');
    expect(await store.readConnectionSecret('a'), 'old-fixture');
    await store.changeConnection('a',
        replacement: {'id': 'a'}, apiKey: 'new-fixture');
    final firstSlot =
        (jsonDecode(prefs.getString('saathi.connections.v1')!) as List)
            .single['secretSlot'] as String;
    expect(await secrets.read('a'), isNull);
    expect(await store.readConnectionSecret('a'), 'new-fixture');
    expect((await store.load()).connections.single.containsKey('secretSlot'),
        isFalse);
    await store.changeConnection('a', replacement: {'id': 'a'}, apiKey: '');
    expect(await secrets.read(firstSlot), isNull);
    expect(await store.readConnectionSecret('a'), isNull);
    final clearedSlot =
        (jsonDecode(prefs.getString('saathi.connections.v1')!) as List)
            .single['secretSlot'] as String;
    await store.changeConnection('a');
    expect(await secrets.read(clearedSlot), isNull);
    expect(await store.readConnectionSecret('a'), isNull);
  });
  test('missing generation never falls back to an old credential', () async {
    final slot = 'credential.v1.${'a' * 48}';
    SharedPreferences.setMockInitialValues({
      'saathi.connections.v1': jsonEncode([
        {'id': 'a', 'secretSlot': slot}
      ]),
    });
    final secrets = MemorySecrets();
    await secrets.write('a', 'must-not-reuse');
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(), secrets: secrets);
    await expectLater(store.readConnectionSecret('a'),
        throwsA(isA<StorageRecoveryException>()));
    await expectLater(
        store.changeConnection('a', replacement: {'id': 'a', 'name': 'Rename'}),
        throwsA(isA<StorageRecoveryException>()));
  });
  test('failed metadata publication restores original generation and cache',
      () async {
    final prefs = FailedChatPreferences();
    final secrets = MemorySecrets();
    final store = SaathiStore(preferences: prefs, secrets: secrets);
    await store.saveConnection({'id': 'a', 'authorityEpoch': 'old'},
        apiKey: 'old-fixture');
    prefs.fail = true;
    await expectLater(
        store.changeConnection('a',
            replacement: {'id': 'a', 'authorityEpoch': 'new'},
            apiKey: 'new-fixture'),
        throwsA(isA<StorageRecoveryException>()));
    expect((await store.load()).connections.single['authorityEpoch'], 'old');
    expect(await store.readConnectionSecret('a'), 'old-fixture');
  });
  test('duplicate creation cannot overwrite an existing credential', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    await store.saveConnection({'id': 'a'}, apiKey: 'old-fixture');
    await expectLater(store.saveConnection({'id': 'a'}, apiKey: 'new-fixture'),
        throwsStateError);
    expect(await store.readConnectionSecret('a'), 'old-fixture');
  });
  test('crash before metadata publication keeps original credential authority',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = PausedSecrets();
    final store = SaathiStore(preferences: prefs, secrets: secrets);
    const original = {'id': 'a', 'authorityEpoch': 'original'};
    await store.saveConnection(original, apiKey: 'old-fixture');
    secrets.written = Completer<void>();
    secrets.release = Completer<void>();
    final pending = store.changeConnection('a',
        replacement: {...original, 'authorityEpoch': 'replacement'},
        apiKey: 'new-fixture');
    await secrets.written!.future;
    try {
      // A fresh process can see the durable secret write but only old metadata.
      final restarted = SaathiStore(preferences: prefs, secrets: secrets);
      final connection = (await restarted.load()).connections.single;
      expect(connection['authorityEpoch'], 'original');
      expect(await restarted.readConnectionSecret('a'), 'old-fixture');
    } finally {
      secrets.release!.complete();
      await pending;
    }
    final committed = (await store.load()).connections.single;
    expect(committed['authorityEpoch'], 'replacement');
    expect(await store.readConnectionSecret('a'), 'new-fixture');
  });
  test('failed chat writes restore cached history for a recreated store',
      () async {
    final prefs = FailedChatPreferences();
    final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
    await store.saveChats([
      {'id': 'keep', 'messages': []}
    ]);
    prefs.fail = true;
    await expectLater(store.saveChats([]), throwsStateError);
    final restarted = SaathiStore(preferences: prefs, secrets: MemorySecrets());
    expect((await restarted.load()).chats.single['id'], 'keep');
  });
  for (final existing in [false, true]) {
    test('throwing chat write restores cache with existing=$existing',
        () async {
      final prefs = FailedChatPreferences();
      final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
      if (existing) {
        await store.saveChats([
          {'id': 'keep', 'messages': []}
        ]);
      }
      prefs.fail = true;
      prefs.throwOnFailure = true;
      await expectLater(
          store.saveChats([
            {'id': 'unsaved', 'messages': []}
          ]),
          throwsStateError);
      final loaded =
          await SaathiStore(preferences: prefs, secrets: MemorySecrets())
              .load();
      expect(loaded.chats.map((c) => c['id']), existing ? ['keep'] : isEmpty);
    });
  }
  test('persistence schemas reject accidental credentials and private metadata',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
    await store.saveConnection({
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'https://example.com',
      'apiKey': 'accidental-secret'
    }, apiKey: 'vault-only');
    await store.saveChats([
      {
        'id': 'c',
        'connectionId': 'a',
        'model': 'small',
        'apiKey': 'accidental-secret',
        'messages': [
          {
            'role': 'model',
            'content': 'Visible',
            'metadata': {
              'reasoning': 'hidden-trace',
              'apiKey': 'accidental-secret'
            }
          }
        ]
      }
    ]);
    final raw = prefs.getKeys().map(prefs.get).join();
    expect(raw, isNot(contains('accidental-secret')));
    expect(raw, isNot(contains('hidden-trace')));
    expect(raw, isNot(contains('vault-only')));
    expect((await store.load()).chats.single['messages'].single['content'],
        'Visible');
  });
  test('credentials are separate from ordinary preferences and survive reload',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecrets();
    final store = SaathiStore(preferences: prefs, secrets: secrets);
    await store.saveConnection({
      'id': 'local',
      'name': 'Local',
      'url': 'http://localhost:8080',
      'type': 'openai'
    }, apiKey: 'secret-token');
    await store.saveChats([
      {'id': 'chat', 'connectionId': 'local', 'messages': []}
    ]);
    expect(
        prefs.getKeys().map(prefs.get).join(), isNot(contains('secret-token')));
    expect(await secrets.read('local'), 'secret-token');
    final loaded = await store.load();
    expect(loaded.connections.single['id'], 'local');
    expect(loaded.chats.single['connectionId'], 'local');
  });
}
