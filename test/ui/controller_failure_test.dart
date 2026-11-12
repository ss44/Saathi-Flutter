import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

class FailingStore extends SaathiStore {
  FailingStore(SharedPreferences preferences)
      : super(preferences: preferences, secrets: MemorySecrets());
  bool fail = false;
  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    if (fail) throw StateError('disk full');
    await super.saveChats(chats);
  }
}

void main() {
  test(
      'successful response with failed persistence is not offered for duplicate resend',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = FailingStore(await SharedPreferences.getInstance());
    final client = MockClient((_) async =>
        http.Response('{"choices":[{"message":{"content":"Done"}}]}', 200));
    final c =
        ChatController(store, coreFactory: () => SaathiCore(client: client));
    await c.load();
    final connection = {
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'https://example.com'
    };
    await c.addConnection(connection, '');
    await c.newSession(connection, 'small', '');
    store.fail = true;
    expect(await c.send('Hello'), isTrue);
    expect(c.current!.messages.length, 2);
    expect(c.error, contains('not saved'));
  });
  test('new and deleted sessions roll back if persistence fails', () async {
    SharedPreferences.setMockInitialValues({});
    final store = FailingStore(await SharedPreferences.getInstance());
    final c = ChatController(store);
    await c.load();
    final connection = {
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'https://example.com'
    };
    await c.addConnection(connection, '');
    await c.newSession(connection, 'small', '');
    final original = c.current;
    store.fail = true;
    await expectLater(c.newSession(connection, 'other', ''), throwsStateError);
    expect(c.current, original);
    expect(c.sessions.length, 1);
    await expectLater(c.clear(), throwsStateError);
    expect(c.current, original);
    expect(c.sessions.length, 1);
  });
}
