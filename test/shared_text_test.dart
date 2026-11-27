import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('saathi/shared_text');
const _composer = Key('composer');

Future<void> _notifyShare(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _channel.name,
    const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('sharedTextAvailable')),
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cold and warm shares stay local and join only the chosen draft',
      (tester) async {
    final pending = Queue.of(['https://example.com/article\nA shared message']);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      (call) async {
        expect(call.method, 'takePendingText');
        return pending.isEmpty ? null : pending.removeFirst();
      },
    );
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets(),
    );
    await store.saveConnection({
      'id': 'local',
      'name': 'Local',
      'url': 'http://localhost:1234',
      'type': 'openai',
    }, apiKey: 'fixture');
    await store.saveChats([
      for (final id in ['a', 'b'])
        {
          'id': id,
          'title': 'Chat ${id.toUpperCase()}',
          'connectionId': 'local',
          'model': 'local',
          'messages': [],
        },
    ]);
    var requests = 0;
    await tester.pumpWidget(SaathiApp(
      store: store,
      coreFactory: () => SaathiCore(client: MockClient((_) async {
        requests++;
        return http.Response(
            '{"choices":[{"message":{"content":"Fixture reply"}}]}', 200);
      })),
    ));
    await tester.pumpAndSettle();
    final c = tester.widget<ChatHome>(find.byType(ChatHome)).controller;
    String draft() =>
        tester.widget<TextField>(find.byKey(_composer)).controller!.text;

    expect(find.text('Add shared text'), findsOneWidget);
    expect(draft(), isEmpty);
    expect(requests, 0);
    c.select(c.sessions.first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(_composer), 'My existing draft');
    await tester.tap(find.text('Add shared text'));
    await tester.pumpAndSettle();
    expect(draft(),
        'My existing draft\n\nhttps://example.com/article\nA shared message');
    expect(find.text('Add shared text'), findsNothing);
    expect(requests, 0);

    c.select(c.sessions.last);
    await tester.pumpAndSettle();
    expect(draft(), isEmpty);
    pending.addAll(['Discard this', 'Warm share']);
    await _notifyShare(tester);
    expect(find.text('Add shared text'), findsOneWidget);
    await tester.tap(find.byTooltip('Discard shared text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add shared text'));
    await tester.pumpAndSettle();
    expect(draft(), 'Warm share');
    await _notifyShare(tester);
    expect(find.text('Add shared text'), findsNothing);
    await tester.enterText(find.byKey(_composer), 'Edited warm share');
    await tester.pumpAndSettle();
    c.select(c.sessions.first);
    await tester.pumpAndSettle();
    expect(draft(),
        'My existing draft\n\nhttps://example.com/article\nA shared message');
    c.select(c.sessions.last);
    await tester.pumpAndSettle();
    expect(draft(), 'Edited warm share');
    expect(requests, 0);
    expect(
        (await store.load())
            .chats
            .every((chat) => (chat['messages'] as List).isEmpty),
        isTrue);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('a warm share during startup waits for a conversation',
      (tester) async {
    final initialReply = Completer<String?>();
    const shared = 'Text shared before any chat exists';
    final pending = Queue.of([shared]);
    var reads = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      (_) async {
        if (++reads == 1) return initialReply.future;
        return pending.isEmpty ? null : pending.removeFirst();
      },
    );
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets(),
    );
    await store.saveConnection({
      'id': 'local',
      'name': 'Local',
      'url': 'http://localhost:1234',
      'type': 'openai',
    }, apiKey: 'fixture');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(SaathiApp(
      store: store,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
    ));
    await tester.pumpAndSettle();
    expect(reads, 1);
    await _notifyShare(tester);
    initialReply.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Open a chat for shared text'), findsOneWidget);
    expect(find.text('Add shared text'), findsNothing);
    final c = tester.widget<ChatHome>(find.byType(ChatHome)).controller;
    await c.newSession(c.connections.single, 'local-model', '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add shared text'));
    await tester.pumpAndSettle();
    expect(find.text('Open a chat for shared text'), findsNothing);
    expect(tester.widget<TextField>(find.byKey(_composer)).controller!.text,
        shared);

    pending.add('x' * ChatController.maxInputLength);
    await _notifyShare(tester);
    final tooLong = find.widgetWithText(TextButton, 'Draft too long');
    expect(tester.widget<TextButton>(tooLong).onPressed, isNull);
    expect(tester.widget<TextField>(find.byKey(_composer)).controller!.text,
        shared);
    await tester.tap(find.byTooltip('Discard shared text'));
    await tester.pumpAndSettle();
    expect(tooLong, findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
