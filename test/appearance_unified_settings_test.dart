import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'appearance_surfaces_test.dart' show appearanceChatStore;

void main() {
  testWidgets(
      'unified Application appearance preserves final bubbles and chat reader without requests',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final store = await appearanceChatStore();
    await store.saveChats([
      {
        'id': 'joint-history',
        'connectionId': 'local',
        'model': 'fixture',
        'messages': [
          for (var i = 0; i < 35; i++)
            {
              'role': i.isEven ? 'user' : 'assistant',
              'content':
                  'History $i with `code` and [link](https://example.test).'
            },
          {'role': 'assistant', 'content': ' \n '},
          {'role': 'tool', 'content': 'Not an answer'},
        ],
      }
    ]);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('{"data":[]}', 200);
    });
    addTearDown(client.close);
    await tester.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await tester.pumpAndSettle();
    final home = find.byType(ChatHome);
    final state = tester.state(home);
    final controller = tester.widget<ChatHome>(home).controller;
    final session = controller.current!;
    final records = List<ChatMessage>.of(session.messages);
    final composer = find.byKey(const Key('composer'));
    await tester.enterText(composer, 'Unsent original draft');
    final field = tester.widget<TextField>(composer);
    final text = field.controller!;
    EditableText editable() => tester.widget<EditableText>(
        find.descendant(of: composer, matching: find.byType(EditableText)));
    final focus = editable().focusNode;
    text.selection = const TextSelection(baseOffset: 2, extentOffset: 8);
    final transcript = tester
        .widgetList<ListView>(find.byType(ListView))
        .singleWhere((list) => list.controller != null)
        .controller!;
    transcript.jumpTo(250);
    await tester.pumpAndSettle();
    final offset = transcript.offset;
    expect(focus.hasFocus, isTrue);

    void checkChat(Brightness brightness) {
      expect(tester.state(home), same(state));
      expect(tester.widget<ChatHome>(home).controller, same(controller));
      expect(controller.current, same(session));
      expect(session.messages, orderedEquals(records));
      expect(tester.widget<TextField>(composer).controller, same(text));
      expect(editable().focusNode, same(focus));
      expect(text.text, 'Unsent original draft');
      expect(
          text.selection, const TextSelection(baseOffset: 2, extentOffset: 8));
      expect(transcript.offset, closeTo(offset, 0.5));
      final scheme = Theme.of(tester.element(home)).colorScheme;
      expect(scheme.brightness, brightness);
      final rows = tester.widgetList<MessageView>(find.byType(MessageView));
      expect(rows.any((row) => row.user), isTrue);
      expect(rows.any((row) => !row.user), isTrue);
      expect(rows.every((row) => row.text.trim().isNotEmpty), isTrue);
      expect(rows.any((row) => row.text == 'Not an answer'), isFalse);
      expect(
          find.descendant(
              of: find.byType(MessageView), matching: find.text('Saathi')),
          findsNothing);
      for (final row in find.byType(MessageView).evaluate()) {
        final widget = row.widget as MessageView;
        final containers = tester.widgetList<Container>(find.descendant(
            of: find.byWidget(widget), matching: find.byType(Container)));
        final bubble =
            containers.firstWhere((c) => c.decoration is BoxDecoration);
        expect(
            (bubble.decoration! as BoxDecoration).color,
            widget.user
                ? scheme.secondaryContainer
                : scheme.surfaceContainerHighest);
        if (widget.user) {
          expect(
              tester
                  .widget<Text>(find.descendant(
                      of: find.byWidget(widget),
                      matching: find.text(widget.text)))
                  .style!
                  .color,
              scheme.onSecondaryContainer);
        } else {
          final markdown = tester.widget<MarkdownBody>(find.descendant(
              of: find.byWidget(widget), matching: find.byType(MarkdownBody)));
          expect(markdown.styleSheet!.a!.color, scheme.primary);
          expect(markdown.styleSheet!.code!.color, scheme.onSurface);
          expect(markdown.styleSheet!.p!.color, scheme.onSurface);
        }
      }
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
    }

    for (final label in ['Dark', 'Light', 'System']) {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionsPage), findsOneWidget);
      expect(find.text('Connections'), findsOneWidget);
      expect(find.text('Application'), findsOneWidget);
      expect(find.text('Current conversation'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Global prompt optimizer'),
          findsOneWidget);
      expect(find.widgetWithText(ListTile, 'App updates'), findsOneWidget);
      final choice = find.byKey(const Key('appearance-choice'));
      expect(choice, findsOneWidget);
      expect(tester.getTopLeft(choice).dy,
          greaterThan(tester.getTopLeft(find.text('Application')).dy));
      expect(tester.getTopLeft(choice).dy,
          lessThan(tester.getTopLeft(find.text('Current conversation')).dy));
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      for (final os in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = os;
        await tester.pumpAndSettle();
        checkChat(label == 'System'
            ? os
            : label == 'Dark'
                ? Brightness.dark
                : Brightness.light);
      }
      // Settings owns focus while open; returning must restore the same draft.
      expect(focus.hasFocus, isTrue);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
