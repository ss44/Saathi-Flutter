import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/ui/appearance.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/chat_home.dart';
import 'appearance_surfaces_test.dart' show appearanceChatStore;

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
      'OS and manual theme changes preserve focused draft selection and reader position',
      (tester) async {
    final store = await appearanceChatStore();
    await store.saveChats([
      {
        'id': 'long-chat',
        'connectionId': 'local',
        'model': 'fixture',
        'messages': [
          for (var i = 0; i < 35; i++)
            {
              'role': i.isEven ? 'user' : 'assistant',
              'content': 'History item $i with a paragraph of text.'
            }
        ],
      }
    ]);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(SaathiApp(store: store));
    await tester.pumpAndSettle();
    final home = find.byType(ChatHome);
    final state = tester.state(home);
    final controller = tester.widget<ChatHome>(home).controller;
    final session = controller.current;
    final input = find.byKey(const Key('composer'));
    await tester.enterText(input, 'Keep this exact draft');
    final editable = tester.widget<EditableText>(
        find.descendant(of: input, matching: find.byType(EditableText)));
    editable.controller.selection =
        const TextSelection(baseOffset: 2, extentOffset: 9);
    final transcript = tester
        .widgetList<ListView>(find.byType(ListView))
        .singleWhere((list) => list.controller != null)
        .controller!;
    transcript.jumpTo(250);
    await tester.pumpAndSettle();
    final offset = transcript.offset;
    final appearance = AppearanceScope.of(tester.element(home))!;
    for (final mode in [
      ThemeMode.system,
      ThemeMode.light,
      ThemeMode.dark,
      ThemeMode.system
    ]) {
      await appearance.select(mode);
      for (final os in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = os;
        await tester.pumpAndSettle();
        expect(tester.state(home), same(state));
        expect(tester.widget<ChatHome>(home).controller, same(controller));
        expect(controller.current, same(session));
        expect(editable.focusNode.hasFocus, isTrue);
        expect(editable.controller.text, 'Keep this exact draft');
        expect(editable.controller.selection,
            const TextSelection(baseOffset: 2, extentOffset: 9));
        expect(transcript.offset, closeTo(offset, 0.5));
      }
    }
  });

  testWidgets(
      'actual Settings appearance leaves active request and captured FIFO source intact',
      (tester) async {
    final store = await appearanceChatStore();
    final reply = Completer<http.Response>();
    final requests = <http.Request>[];
    final client = MockClient((request) {
      requests.add(request);
      return reply.future;
    });
    addTearDown(client.close);
    await tester.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await tester.pumpAndSettle();
    final home = find.byType(ChatHome);
    final controller = tester.widget<ChatHome>(home).controller;
    final state = tester.state(home);
    final session = controller.current!;
    final connection = controller.connections.single;
    final input = find.byKey(const Key('composer'));
    await tester.enterText(input, 'Accepted original input');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await frames(tester);
    expect(requests, hasLength(1));
    expect(controller.busy, isTrue);
    expect(find.byType(BusyThinking), findsOneWidget);
    expect(controller.submit('Queued original follower'), isTrue);
    final queued = controller.outbox.single;
    final captured = queued.preparedJson('prepared');
    controller.pauseQueue('Explicit review pause');
    final pause = controller.queueStatus;
    await tester.enterText(input, 'Unsent newer draft');
    final text = tester.widget<TextField>(input).controller!;
    text.selection = const TextSelection(baseOffset: 1, extentOffset: 7);
    await tester.tap(find.byTooltip('Settings'));
    await frames(tester);
    final choice = find.byKey(const Key('appearance-choice'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await frames(tester);
    await tester.tap(find.text('Dark').last);
    await frames(tester);
    expect(Theme.of(tester.element(choice)).brightness, Brightness.dark);
    await tester.pageBack();
    await frames(tester);
    expect(tester.state(home), same(state));
    expect(controller.current, same(session));
    expect(controller.connections.single, same(connection));
    expect(controller.outbox.single, same(queued));
    expect(queued.connection, same(connection));
    expect(queued.session, same(session));
    expect(queued.preparedJson('prepared'), captured);
    expect(controller.queueStatus, pause);
    expect(controller.busy, isTrue);
    expect(text.text, 'Unsent newer draft');
    expect(text.selection, const TextSelection(baseOffset: 1, extentOffset: 7));
    expect(requests, hasLength(1));
    expect(jsonDecode(requests.single.body)['model'], session.model);
    reply.complete(http.Response(
        '{"choices":[{"message":{"content":"Controlled answer"}}]}', 200));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && controller.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await frames(tester);
    expect(controller.busy, isFalse);
    expect(requests, hasLength(1));
    expect(controller.outbox.single, same(queued));
    expect(controller.queueStatus, pause);
    expect(session.messages.last.content, 'Controlled answer');
    expect(text.text, 'Unsent newer draft');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
