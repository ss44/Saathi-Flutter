import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/main.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_home.dart';

Future<SaathiStore> makeStore() async {
  SharedPreferences.setMockInitialValues({});
  return SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets());
}

void main() {
  testWidgets(
      'add connection, discover, select model, send, copy and reveal activity',
      (tester) async {
    final store = await makeStore();
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return http.Response('{"data":[{"id":"small-model"}]}', 200);
      }
      return http.Response(
          '{"choices":[{"message":{"content":"A **real** reply"}}]}', 200);
    });
    await tester.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect a model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add connection'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Connection name'), 'Local model');
    await tester.enterText(find.widgetWithText(TextFormField, 'API base URL'),
        'http://localhost:1234');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'API key / token'),
        'not-a-real-key');
    await tester.ensureVisible(find.text('Save connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Discover models'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Available models'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('small-model').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start conversation'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('composer')), 'Hello');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Send'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.byType(MessageView), findsNWidgets(2));
    expect(find.textContaining('Activity ·'), findsNothing);
    await tester.drag(find.byType(MessageView).last, const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('Activity · Response received'), findsOneWidget);
    await tester.longPress(find.text('Hello'));
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsOneWidget);
    expect(copied, 'Hello');
    final body = jsonDecode(requests.last.body);
    expect(body['model'], 'small-model');
    expect(body['messages'].single['content'], 'Hello');
    expect(requests.last.headers['authorization'], 'Bearer not-a-real-key');
    expect(store.preferences.getKeys().map(store.preferences.get).join(),
        isNot(contains('not-a-real-key')));
    await tester.tap(find.byTooltip('Connection settings'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.byType(MessageView), findsNWidgets(2));
    await tester.longPress(find.byType(MessageView).last);
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsOneWidget);
    expect(copied, 'A **real** reply');
    await tester.tap(find.byTooltip('Delete conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect((await store.load()).chats, isEmpty);
    expect(find.text('Hello'), findsNothing);
  });

  testWidgets(
      'provider error is safe, leaves no fabricated response and permits retry',
      (tester) async {
    final store = await makeStore();
    await store.saveConnection({
      'id': 'a',
      'name': 'A',
      'url': 'http://localhost:1234',
      'type': 'openai'
    }, apiKey: 'private-key');
    await store.saveChats([
      {'id': 'c', 'connectionId': 'a', 'model': 'local', 'messages': []}
    ]);
    final client = MockClient(
        (_) async => http.Response('private-key secret server details', 401));
    await tester.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('composer')), 'Try this');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Send'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-error')), findsOneWidget);
    expect(find.textContaining('private-key'), findsNothing);
    expect(find.byType(MessageView), findsNothing);
    expect(find.widgetWithText(TextField, 'Try this'), findsOneWidget);
    expect((await store.load()).chats.single['messages'], isEmpty);
  });
}
