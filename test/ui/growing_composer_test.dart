import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'controller_http_test.dart' show makeStore;

void main() {
  for (final width in [360.0, 390.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final keyboard in [0.0, 300.0]) {
        testWidgets(
            'composer grows to twice input height $width/$scale/$keyboard',
            (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          tester.view.viewPadding = const FakeViewPadding(bottom: 24);
          tester.view.padding = FakeViewPadding(bottom: keyboard == 0 ? 24 : 0);
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          addTearDown(tester.view.reset);
          final controller = ChatController(await makeStore());
          await controller.load();
          final connection = {
            'id': 'a',
            'name': 'A',
            'type': 'openai',
            'url': 'https://example.com',
          };
          await controller.addConnection(connection, '');
          await controller.newSession(connection, 'small', '');
          await tester.pumpWidget(MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: ChatHome(controller: controller),
          ));
          final input = find.byKey(const Key('composer'));
          final emptyHeight = tester.getSize(input).height;
          await tester.enterText(input, 'Short');
          await tester.pumpAndSettle();
          expect(tester.getSize(input).height, emptyHeight);
          await tester.enterText(input, 'First\nSecond');
          await tester.pumpAndSettle();
          expect(tester.getSize(input).height, greaterThan(emptyHeight));
          final longDraft = 'A long naturally wrapped draft. ' * 100;
          await tester.enterText(input, longDraft);
          await tester.pumpAndSettle();
          expect(tester.getSize(input).height, closeTo(emptyHeight * 2, 1),
              reason: 'Cap the input, not the screen or a fixed line count');
          final capped = tester.getRect(input);
          final field = tester.widget<TextField>(input);
          final editable =
              find.descendant(of: input, matching: find.byType(EditableText));
          final state = tester.state<EditableTextState>(editable);
          final draftScroll = tester.state<ScrollableState>(
              find.descendant(of: editable, matching: find.byType(Scrollable)));
          expect(draftScroll.position.maxScrollExtent, greaterThan(0));
          expect(state.widget.focusNode.hasFocus, isTrue);
          final value = field.controller!.value;
          final beforeScroll = draftScroll.position.pixels;
          await tester.drag(input, const Offset(0, 70));
          await tester.pumpAndSettle();
          expect(draftScroll.position.pixels, lessThan(beforeScroll));
          expect(tester.getRect(input), capped);
          expect(field.controller!.value, value);
          field.controller!.selection = TextSelection(
              baseOffset: longDraft.length - 4,
              extentOffset: longDraft.length - 1);
          await tester.pumpAndSettle();
          final menuValue = field.controller!.value;
          // Editing at the caret, rather than browsing away from it: the native
          // field intentionally reveals that caret when menu focus returns.
          draftScroll.position.jumpTo(draftScroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          final scrollBeforeMenu = draftScroll.position.pixels;
          await tester.longPress(find.byTooltip('Send'));
          await tester.pumpAndSettle();
          expect(find.text('Optimize prompt'), findsOneWidget);
          await tester.tapAt(const Offset(4, 200));
          await tester.pumpAndSettle();
          expect(field.controller!.value, menuValue);
          expect(state.widget.focusNode.hasFocus, isTrue);
          expect(draftScroll.position.pixels, closeTo(scrollBeforeMenu, .01));
          tester.view.viewInsets =
              FakeViewPadding(bottom: keyboard == 0 ? 300 : 0);
          tester.view.padding = FakeViewPadding(bottom: keyboard == 0 ? 0 : 24);
          await tester.pumpAndSettle();
          expect(tester.getSize(input).height, capped.height);
          expect(field.controller!.value, menuValue);
          expect(state.widget.focusNode.hasFocus, isTrue);
          expect(draftScroll.position.pixels, closeTo(scrollBeforeMenu, .01));
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          tester.view.padding = FakeViewPadding(bottom: keyboard == 0 ? 24 : 0);
          await tester.pumpAndSettle();
          expect(find.byTooltip('Send').hitTestable(), findsOneWidget);
          final safe =
              find.ancestor(of: input, matching: find.byType(SafeArea)).first;
          expect(tester.getBottomLeft(safe).dy, closeTo(844 - keyboard, .01));
          expect(capped.bottom,
              lessThanOrEqualTo(844 - keyboard - (keyboard == 0 ? 24 : 0)));
          await tester.enterText(input, 'Short');
          await tester.pumpAndSettle();
          expect(tester.getSize(input).height, emptyHeight);
          expect(state.widget.focusNode.hasFocus, isTrue);
          await tester.enterText(input, '');
          await tester.pumpAndSettle();
          expect(tester.getSize(input).height, emptyHeight);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        });
      }
    }
  }
}
