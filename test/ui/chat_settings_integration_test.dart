import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/chat_settings_panel.dart';
import 'package:saathi/ui/connections.dart';

import '../appearance_surfaces_test.dart' show appearanceChatStore;

void main() {
  testWidgets(
      'desktop panel and unified appearance preserve chat and accepted context',
      (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1440, 900);
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final store = await appearanceChatStore();
    await store.saveChats([
      {
        'id': 'joint-history',
        'connectionId': 'local',
        'model': 'original-model',
        'systemPrompt': 'Original instructions',
        'messages': [
          for (var i = 0; i < 50; i++)
            {
              'role': i.isEven ? 'user' : 'assistant',
              'content':
                  'Row $i with `code` and [link](https://example.test). ${'Variable reader paragraph. ' * (1 + i % 5)}'
            },
          {'role': 'assistant', 'content': ' \n '},
          {'role': 'tool', 'content': 'Not an answer'},
        ],
      }
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
    final homeState = t.state(home);
    final c = t.widget<ChatHome>(home).controller;
    final session = c.current!;
    final source = c.connections.single;
    final records = List<ChatMessage>.of(session.messages);
    final composer = find.byKey(const Key('composer'));
    await t.enterText(composer, 'Unsent original draft');
    final text = t.widget<TextField>(composer).controller!;
    final editable = t.state<EditableTextState>(
        find.descendant(of: composer, matching: find.byType(EditableText)));
    final focus = editable.widget.focusNode;
    text.selection = const TextSelection(baseOffset: 2, extentOffset: 8);
    final transcript =
        find.byWidgetPredicate((w) => w is ListView && w.controller != null);
    final scroll = t.widget<ListView>(transcript).controller!;
    scroll.jumpTo(1700);
    await t.pumpAndSettle();
    final top = t.getRect(transcript).top;
    final row = find
        .byType(MessageView)
        .evaluate()
        .firstWhere((e) => t.getRect(find.byWidget(e.widget)).bottom > top);
    final anchorText = (row.widget as MessageView).text;
    final anchor =
        find.byWidgetPredicate((w) => w is MessageView && w.text == anchorText);
    final anchorY = t.getRect(anchor).top;

    void checkRetainedChat() {
      expect(t.state(home), same(homeState));
      expect(c.current, same(session));
      expect(c.connections.single, same(source));
      expect(session.messages, orderedEquals(records));
      expect(t.widget<TextField>(composer).controller, same(text));
      expect(editable.mounted, isTrue);
      expect(editable.widget.focusNode, same(focus));
      expect(text.text, 'Unsent original draft');
      expect(
          text.selection, const TextSelection(baseOffset: 2, extentOffset: 8));
      expect(t.getRect(anchor).top, closeTo(anchorY, 1));
      expect(requests, isEmpty);
      expect(t.takeException(), isNull);
    }

    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(find.byKey(const Key('chat-settings-panel')), findsOneWidget);
    expect(t.getRect(find.byKey(const Key('chat-settings-panel'))).left,
        greaterThanOrEqualTo(t.getRect(composer).right));
    final panelState = t.state(find.byType(ChatSettingsPanel));
    checkRetainedChat();
    await t.enterText(
        find.byKey(const Key('chat-reply-model')), 'uncommitted-model');
    await t.enterText(
        find.byKey(const Key('chat-instructions')), 'Uncommitted instructions');

    for (final label in ['Dark', 'Light', 'System']) {
      await t.tap(find.descendant(
          of: find.byType(NavigationRail), matching: find.text('Settings')));
      await t.pumpAndSettle();
      expect(find.byType(ConnectionsPage), findsOneWidget);
      expect(find.text('Application'), findsOneWidget);
      expect(find.text('Current conversation'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Global prompt optimizer'),
          findsOneWidget);
      expect(find.byTooltip('Chat settings'), findsNothing);
      final choice = find.byKey(const Key('appearance-choice'));
      await t.ensureVisible(choice);
      await t.tap(choice);
      await t.pumpAndSettle();
      await t.tap(find.text(label).last);
      await t.pumpAndSettle();
      // The integrated desktop Back guard returns to Chats, not out of the app.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(ConnectionsPage), findsNothing);
      expect(t.state(find.byType(ChatSettingsPanel)), same(panelState));
      expect(
          t
              .widget<TextField>(find.byKey(const Key('chat-reply-model')))
              .controller!
              .text,
          'uncommitted-model');
      for (final os in Brightness.values) {
        t.platformDispatcher.platformBrightnessTestValue = os;
        await t.pumpAndSettle();
        final scheme = Theme.of(t.element(home)).colorScheme;
        expect(
            scheme.brightness,
            label == 'System'
                ? os
                : label == 'Dark'
                    ? Brightness.dark
                    : Brightness.light);
        expect(
            t
                .widget<Material>(find.byKey(const Key('chat-settings-panel')))
                .color,
            scheme.surface);
        final rows = t.widgetList<MessageView>(find.byType(MessageView));
        expect(rows.any((w) => w.user), isTrue);
        expect(rows.any((w) => !w.user), isTrue);
        expect(rows.every((w) => w.text.trim().isNotEmpty), isTrue);
        expect(rows.any((w) => w.text == 'Not an answer'), isFalse);
        for (final message in rows) {
          final owner = find.byWidget(message);
          final bubble = t
              .widgetList<Container>(
                  find.descendant(of: owner, matching: find.byType(Container)))
              .firstWhere((w) => w.decoration is BoxDecoration);
          expect(
              (bubble.decoration! as BoxDecoration).color,
              message.user
                  ? scheme.secondaryContainer
                  : scheme.surfaceContainerHighest);
          if (!message.user) {
            final markdown = t.widget<MarkdownBody>(find.descendant(
                of: owner, matching: find.byType(MarkdownBody)));
            expect(markdown.styleSheet!.a!.color, scheme.primary);
            expect(markdown.styleSheet!.p!.color, scheme.onSurface);
            expect(markdown.styleSheet!.code!.color, scheme.onSurface);
          }
        }
        checkRetainedChat();
      }
      expect(c.replyModel(session), 'original-model');
    }
    // Pointer-only panel opening/Cancel must not steal an existing draft focus.
    focus.requestFocus();
    await t.pump();
    await t.ensureVisible(find.widgetWithText(TextButton, 'Cancel'));
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await t.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    checkRetainedChat();
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(
        t
            .widget<TextField>(find.byKey(const Key('chat-reply-model')))
            .controller!
            .text,
        'original-model');
    await t.enterText(
        find.byKey(const Key('chat-reply-model')), 'accepted-model');
    await t.enterText(
        find.byKey(const Key('chat-instructions')), 'Accepted instructions');
    await t.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(c.replyModel(session), 'accepted-model');
    expect(session.model, 'original-model');
    checkRetainedChat();

    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const Key('chat-reply-model')), 'future-not-saved');
    await t.enterText(
        find.byKey(const Key('chat-instructions')), 'Future not saved');
    await t.enterText(composer, 'Accepted input');
    await t.pump();
    await t.tap(find.byTooltip('Send'));
    for (var i = 0; i < 40 && requests.isEmpty; i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(requests, hasLength(1));
    await t.enterText(composer, 'Queued input');
    await t.pump();
    await t.tap(find.byTooltip('Send'));
    c.pauseQueue('Deliberate integration hold');
    await t.pump();
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    expect(c.outbox.single.model, 'accepted-model');
    expect(c.outbox.single.captured.instructions, 'Accepted instructions');
    final payload = jsonDecode(requests.single.body) as Map;
    expect(payload['model'], 'accepted-model');
    expect((payload['messages'] as List).first['content'],
        'Accepted instructions');
    expect(requests.single.url.host, 'example.test');
    expect(requests.single.headers['Authorization'], 'Bearer fixture-only');
    response.complete(http.Response(
        '{"choices":[{"message":{"content":"Controlled answer"}}]}', 200));
    for (var i = 0; i < 40 && c.busy; i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await t.pumpAndSettle();
    expect(c.busy, isFalse);
    expect(c.current, same(session));
    expect(c.current!.messages.last.content, 'Controlled answer');
    expect(requests, hasLength(1));
    expect(c.outbox.single.model, 'accepted-model');
    expect(c.outbox.single.captured.instructions, 'Accepted instructions');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
