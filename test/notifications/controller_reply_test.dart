import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import '../ui/controller_failure_test.dart' show FailingStore;

void main() {
  test(
      'captured conversation completion once despite storage failure and throwing callback',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = FailingStore(await SharedPreferences.getInstance());
    final response = Completer<http.Response>();
    var sends = 0;
    final c = ChatController(store,
        coreFactory: () => SaathiCore(client: MockClient((_) {
              sends++;
              return response.future;
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
    final original = c.current!;
    final other = ChatSession(id: 'other', connectionId: 'a', model: 'small');
    c.sessions.add(other);
    expect(c.openNotificationConversation('missing'), isFalse);
    expect(c.current, original);
    expect(c.openNotificationConversation('other'), isTrue);
    expect(c.current, other);
    c.select(original);
    final received = <String>[];
    c.onReplyReceived = (id) {
      received.add(id);
      throw StateError('OS unavailable');
    };
    final sending = c.send('hello');
    c.select(other);
    store.fail = true;
    response.complete(
        http.Response('{"choices":[{"message":{"content":"Done"}}]}', 200));
    expect(await sending, isTrue);
    expect(received, [original.id]);
    expect(original.messages.length, 2);
    expect(other.messages, isEmpty);
    await c.retrySave();
    expect(received, [original.id]);
    expect(sends, 1);
    c.dispose();
  });
}
