import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

import 'controller_http_test.dart' show makeStore;

Future<ChatController> openPanel(WidgetTester t,
    {String type = 'openai', double scale = 1}) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final c = ChatController(await makeStore());
  await c.load();
  await c.addConnection({
    'id': 'a',
    'name': 'Original connection',
    'type': type,
    'url': 'https://example.com'
  }, '');
  await c.newSession(
      c.connections.single, 'original-model', 'Original instructions');
  await t.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: ChatHome(controller: c)));
  await t.pumpAndSettle();
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  await t.tap(find.byTooltip('Chat settings'));
  await t.pumpAndSettle();
  return c;
}

void main() {
  testWidgets(
      'opening and closing settings preserves the visible reader anchor',
      (t) async {
    final c = await openPanel(t);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    t.view.physicalSize = const Size(1024, 900);
    await t.pumpAndSettle();
    c.current!.messages.addAll(List.generate(
        50,
        (i) => ChatMessage(
            role: 'assistant',
            content:
                'Row $i ${'A variable-length paragraph for the reader. ' * (2 + i % 5)}')));
    c.select(c.current!);
    await t.pumpAndSettle();
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
    final text = (row.widget as MessageView).text;
    final anchor =
        find.byWidgetPredicate((w) => w is MessageView && w.text == text);
    final y = t.getRect(anchor).top;
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(t.getRect(anchor).top, closeTo(y, 1));
    await t.ensureVisible(find.text('Cancel'));
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(t.getRect(anchor).top, closeTo(y, 1));
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
      'large text panel supports keyboard traversal and Save without pointer scrolling',
      (t) async {
    final c = await openPanel(t, scale: 2);
    t.view.physicalSize = const Size(1440, 700);
    await t.pumpAndSettle();
    final model = find.byKey(const Key('chat-reply-model'));
    await t.tap(model);
    await t.enterText(model, 'keyboard-model');
    final save = find.widgetWithText(FilledButton, 'Save');
    var reached = false;
    for (var i = 0; i < 10; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      if (identical(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<FilledButton>(),
          t.widget(save))) {
        reached = true;
        break;
      }
    }
    expect(reached, isTrue);
    expect(save.hitTestable(), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(c.replyModel(c.current!), 'keyboard-model');
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets('resize retains unsaved settings without adding a mobile surface',
      (t) async {
    final c = await openPanel(t);
    await t.enterText(
        find.byKey(const Key('chat-reply-model')), 'unsaved-resize');
    t.view.physicalSize = const Size(390, 844);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(find.byTooltip('Chat settings'), findsNothing);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(c.replyModel(c.current!), 'original-model');
    t.view.physicalSize = const Size(1440, 900);
    await t.pumpAndSettle();
    expect(
        t
            .widget<TextField>(find.byKey(const Key('chat-reply-model')))
            .controller!
            .text,
        'unsaved-resize');
    await t.tap(find.byKey(const Key('chat-reply-model')));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(t.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('native session settings fail closed even without a remote ID',
      (t) async {
    final c = await openPanel(t, type: 'hermesGateway');
    expect(
        t.widget<TextField>(find.byKey(const Key('chat-reply-model'))).enabled,
        isFalse);
    expect(find.textContaining('no verified contract'), findsOneWidget);
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    await expectLater(
        c.saveChatSettings(c.current!,
            originalConnection: c.connections.single,
            selection: c.selectionGeneration,
            model: 'not-native',
            instructions: 'not-native',
            personaId: null),
        throwsStateError);
    expect(c.replyModel(c.current!), 'original-model');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets(
      'persona choice uses shared instructions without editing other chats',
      (t) async {
    final c = await openPanel(t);
    await c.organization.savePersona(
        const SharedPersona(
            id: 'shared',
            name: 'Shared helper',
            instructions: 'Shared instructions'),
        canEdit: (_) => null);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chat-persona')));
    await t.pumpAndSettle();
    await t.tap(find.text('Shared helper').last);
    await t.pumpAndSettle();
    expect(find.text('Shared instructions'), findsOneWidget);
    expect(
        t.widget<TextField>(find.byKey(const Key('chat-instructions'))).enabled,
        isFalse);
    expect(c.organization.entry(c.identityOf(c.current!)).personaId, isNull);
    await t.ensureVisible(find.text('Save'));
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(c.organization.entry(c.identityOf(c.current!)).personaId, 'shared');
    expect(c.organization.personas.single.revision, 1);
    final restored = ChatOrganization(OrganizationStorage(c.store.preferences));
    await restored.load();
    expect(
        restored
            .captureInstructions(c.identityOf(c.current!), fallback: '')
            .instructions,
        'Shared instructions');
    restored.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('source selection closes the old panel permanently', (t) async {
    final c = await openPanel(t);
    final first = c.current!;
    await t.enterText(find.byKey(const Key('chat-reply-model')), 'discard-me');
    await c.newSession(c.connections.single, 'other-model', '');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    c.select(first);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(c.replyModel(first), 'original-model');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets(
      'Save commits reply model and chat instructions only for future input',
      (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
          '{"choices":[{"message":{"content":"Fixture answer"}}]}', 200);
    });
    final store = await makeStore();
    final c =
        ChatController(store, coreFactory: () => SaathiCore(client: client));
    await c.load();
    await c.addConnection({
      'id': 'a',
      'name': 'Original connection',
      'type': 'openai',
      'url': 'https://example.com'
    }, '');
    await c.newSession(
        c.connections.single, 'original-model', 'Original instructions');
    final original = c.current!;
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const Key('chat-reply-model')), 'future-model');
    await t.enterText(
        find.byKey(const Key('chat-instructions')), 'Future instructions');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(
        t
            .widget<TextField>(find.byKey(const Key('chat-reply-model')))
            .controller!
            .text,
        'original-model');
    await t.enterText(
        find.byKey(const Key('chat-reply-model')), 'future-model');
    await t.enterText(
        find.byKey(const Key('chat-instructions')), 'Future instructions');
    await t.ensureVisible(find.text('Save'));
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(requests, isEmpty);
    expect(c.current, same(original));
    expect(c.connections.single['name'], 'Original connection');
    await t.pumpWidget(const SizedBox());
    c.dispose();
    final restored =
        ChatController(store, coreFactory: () => SaathiCore(client: client));
    await restored.load();
    restored.select(restored.sessions.single);
    expect(await t.runAsync(() => restored.send('New input')), isTrue);
    final payload = jsonDecode(requests.single.body) as Map;
    expect(payload['model'], 'future-model');
    expect(
        (payload['messages'] as List).first['content'], 'Future instructions');
    expect(requests.single.url.host, 'example.com');
    restored.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets('desktop opens contextual panel without replacing composer',
      (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = ChatController(await makeStore());
    await c.load();
    await c.addConnection({
      'id': 'a',
      'name': 'Original connection',
      'type': 'openai',
      'url': 'https://example.com',
    }, '');
    await c.newSession(
        c.connections.single, 'original-model', 'Original instructions');
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    final composer = find.byKey(const Key('composer'));
    await t.enterText(composer, 'Unsent draft');
    final editable = t.state<EditableTextState>(
        find.descendant(of: composer, matching: find.byType(EditableText)));
    await t.tap(find.byTooltip('Chat settings'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsOneWidget);
    expect(editable.mounted, isTrue);
    expect(editable.widget.focusNode.hasFocus, isTrue);
    expect(t.widget<TextField>(composer).controller!.text, 'Unsent draft');
    expect(t.getRect(find.byKey(const Key('chat-settings-panel'))).left,
        greaterThanOrEqualTo(t.getRect(composer).right));
    expect(find.byTooltip('Settings'), findsNothing);
    expect(c.current!.messages, isEmpty);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chat-settings-panel')), findsNothing);
    expect(editable.widget.focusNode.hasFocus, isTrue);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
