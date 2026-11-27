import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/chat_home.dart';

import '../appearance_surfaces_test.dart' show appearanceChatStore;

void main() {
  testWidgets('thinking and empty terminal preserve settings draft and reader',
      (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1440, 900);
    addTearDown(t.view.reset);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final store = await appearanceChatStore();
    await store.saveChats([
      {
        'id': 'thinking-settings-reader',
        'connectionId': 'local',
        'model': 'original-model',
        'systemPrompt': 'Original instructions',
        'messages': [
          for (var i = 0; i < 50; i++)
            {
              'role': i.isEven ? 'user' : 'assistant',
              'content': 'Row $i. ${'Reader paragraph. ' * (1 + i % 5)}',
            },
        ],
      },
    ]);
    final response = Completer<http.Response>();
    final requests = <http.Request>[];
    final client = MockClient((request) {
      requests.add(request);
      return response.future;
    });
    addTearDown(client.close);
    await t.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await t.pumpAndSettle();
    final home = find.byType(ChatHome);
    final state = t.state(home);
    final c = t.widget<ChatHome>(home).controller;
    final original = c.current!;
    final source = c.connections.single;
    final composer = find.byKey(const Key('composer'));
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    final model = find.byKey(const Key('chat-reply-model'));
    await t.enterText(model, 'unsaved-panel-model');
    await t.enterText(composer, 'Accepted original input');
    await t.pump();
    await t.tap(find.byTooltip('Send'));
    for (var i = 0; i < 60 && requests.isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 10));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(requests, hasLength(1));
    expect(c.showPendingThinking, isTrue);
    final transcript =
        find.byWidgetPredicate((w) => w is ListView && w.controller != null);
    final scroll = t.widget<ListView>(transcript).controller!;
    for (var i = 0; i < 12; i++) {
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await t.pump(const Duration(milliseconds: 30));
    }
    expect(find.byType(BusyThinking), findsOneWidget);
    expect(find.byType(ShaderMask), findsOneWidget);
    await t.enterText(composer, 'Newer unsent draft');
    await t.pump();
    scroll.jumpTo(800);
    await t.pump(const Duration(milliseconds: 100));
    final top = t.getRect(transcript).top;
    final visible = find
        .byType(MessageView)
        .evaluate()
        .firstWhere((e) => t.getRect(find.byWidget(e.widget)).bottom > top);
    final anchorText = (visible.widget as MessageView).text;
    final anchor =
        find.byWidgetPredicate((w) => w is MessageView && w.text == anchorText);
    final anchorY = t.getRect(anchor).top;
    response.complete(
        http.Response('{"choices":[{"message":{"content":"  "}}]}', 200));
    for (var i = 0; i < 60 && c.busy; i++) {
      await t.pump(const Duration(milliseconds: 10));
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await t.pump();
    expect(c.busy, isFalse);
    expect(c.showPendingThinking, isFalse);
    expect(find.byType(BusyThinking), findsNothing);
    expect(c.error, contains('without a text response'));
    expect(find.byKey(const Key('chat-error')), findsOneWidget);
    expect(t.state(home), same(state));
    expect(c.current, same(original));
    expect(c.connections.single, same(source));
    expect(c.replyModel(original), 'original-model');
    expect(t.widget<TextField>(model).controller!.text, 'unsaved-panel-model');
    expect(
        t.widget<TextField>(composer).controller!.text, 'Newer unsent draft');
    expect(t.getRect(anchor).top, closeTo(anchorY, 1));
    expect(requests, hasLength(1));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
