import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
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
