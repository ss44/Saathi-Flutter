import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

import 'controller_http_test.dart' show makeStore;
import 'chat_settings_safety_test.dart' show setupChat, showPanel;

void main() {
  testWidgets('keyboard never enters the hidden conversation list', (t) async {
    final c = ChatController(await makeStore());
    await setupChat(c);
    await showPanel(t, c);
    await t.tap(find.byKey(const Key('chat-reply-model')));
    for (var i = 0; i < 35; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      final field = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>();
      expect(field?.key, isNot(const Key('local-history-search')));
    }
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets('credential replacement revokes an open settings draft',
      (t) async {
    final c = ChatController(await makeStore());
    await setupChat(c);
    await showPanel(t, c);
    await t.enterText(find.byKey(const Key('chat-reply-model')), 'stale-model');
    final oldConnection = c.connections.single;
    final selection = c.selectionGeneration;
    await c.updateConnection('a', oldConnection, apiKey: 'replacement-fixture');
    await t.pumpAndSettle();
    expect(find.textContaining('connection changed'), findsOneWidget);
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    await expectLater(
        c.saveChatSettings(c.current!,
            originalConnection: oldConnection,
            selection: selection,
            model: 'stale-model',
            instructions: '',
            personaId: null),
        throwsStateError);
    await t.ensureVisible(find.text('Cancel'));
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNotNull);
    expect(
        t
            .widget<TextField>(find.byKey(const Key('chat-reply-model')))
            .controller!
            .text,
        'original');
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('contextual panel can be opened entirely from keyboard',
      (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = ChatController(await makeStore());
    await setupChat(c);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    var reached = false;
    for (var i = 0; i < 40; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      final button = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<IconButton>();
      if (button?.tooltip == 'Chat settings') {
        reached = true;
        break;
      }
    }
    expect(reached, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsOneWidget);
    expect(c.current!.messages, isEmpty);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('mobile exposes unified chat settings safely at $size',
        (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = ChatController(await makeStore());
      await setupChat(c);
      await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
      await t.pumpAndSettle();
      expect(find.byTooltip('Chat settings'), findsOneWidget);
      expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
      expect(find.byTooltip('Send'), findsOneWidget);
      await t.tap(find.byTooltip('Chat settings'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('chat-settings-panel')), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Cancel'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
      expect(find.byTooltip('Send'), findsOneWidget);
      expect(c.replyModel(c.current!), 'original');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
