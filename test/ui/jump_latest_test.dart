import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'controller_http_test.dart' show makeStore;

void main() {
  for (final width in [360.0, 390.0]) {
    testWidgets('gesture, draft, keyboard and selection at $width / 2x',
        (t) async {
      t.view.physicalSize = Size(width, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetViewInsets);
      final c = ChatController(await makeStore());
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
      original.messages.addAll(List.generate(
          60,
          (i) => ChatMessage(
              role: 'model',
              content: 'History row $i with enough text to scroll.')));
      await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(2), disableAnimations: true),
            child: child!),
        home: ChatHome(controller: c),
      ));
      await t.pumpAndSettle();
      final list = find.byType(ListView).first;
      final controller = t.widget<ListView>(list).controller!;
      final button = find.byTooltip('Jump to latest');
      final input = find.byKey(const Key('composer'));
      controller.jumpTo(controller.position.maxScrollExtent);
      await t.pumpAndSettle();
      expect(button, findsNothing);
      await t.enterText(input, 'Unsent draft');
      await t.pumpAndSettle();
      final editable = t.widget<EditableText>(
          find.descendant(of: input, matching: find.byType(EditableText)));
      expect(editable.focusNode.hasFocus, isTrue);
      await t.drag(list, const Offset(0, 1800));
      await t.pumpAndSettle();
      expect(button, findsOneWidget);
      final before = controller.offset;
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await t.pumpAndSettle();
      expect(controller.offset, before);
      expect(button, findsOneWidget);
      final rect = t.getRect(button);
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(rect.bottom, lessThanOrEqualTo(t.getRect(input).top));
      final semantics = t.ensureSemantics();
      expect(
          t.getSemantics(button),
          matchesSemantics(
              label: 'Jump to latest',
              isButton: true,
              hasEnabledState: true,
              isEnabled: true,
              isFocusable: true,
              hasTapAction: true,
              hasFocusAction: true));
      semantics.dispose();
      await t.tap(button);
      await t.pump();
      expect(controller.position.extentAfter, 0);
      expect(editable.focusNode.hasFocus, isTrue);
      expect(t.widget<TextField>(input).controller!.text, 'Unsent draft');
      await t.pumpAndSettle();
      expect(button, findsNothing);
      // A shrinking viewport must use its new height, not the screen height.
      controller.jumpTo(controller.position.maxScrollExtent -
          controller.position.viewportDimension -
          1);
      await t.pumpAndSettle();
      expect(button, findsOneWidget);
      final keyboardViewport = controller.position.viewportDimension;
      expect(controller.position.extentAfter, greaterThan(keyboardViewport));
      t.view.viewInsets = const FakeViewPadding();
      await t.pumpAndSettle();
      expect(
          controller.position.viewportDimension, greaterThan(keyboardViewport));
      expect(controller.position.extentAfter,
          lessThanOrEqualTo(controller.position.viewportDimension));
      expect(button, findsNothing);
      // Start below the current threshold, close enough for real input growth
      // to cross it; keyboard dismissal alone leaves the reader too near latest.
      await t.enterText(input, 'Short');
      await t.pumpAndSettle();
      final shortHeight = t.getSize(input).height;
      final shortViewport = controller.position.viewportDimension;
      final distanceBeforeGrowth = shortViewport - shortHeight / 2;
      controller
          .jumpTo(controller.position.maxScrollExtent - distanceBeforeGrowth);
      await t.pumpAndSettle();
      final readerOffset = controller.offset;
      expect(
          controller.position.extentAfter, closeTo(distanceBeforeGrowth, .01));
      expect(controller.position.extentAfter, lessThan(shortViewport));
      expect(button, findsNothing);
      final longDraft = 'Growing draft ' * 80;
      await t.enterText(input, longDraft);
      await t.pumpAndSettle();
      final grownHeight = t.getSize(input).height;
      expect(grownHeight, greaterThan(shortHeight));
      expect(controller.position.viewportDimension,
          closeTo(shortViewport - (grownHeight - shortHeight), .01));
      expect(controller.offset, readerOffset);
      expect(controller.position.extentAfter,
          greaterThan(controller.position.viewportDimension));
      expect(button, findsOneWidget);
      expect(editable.focusNode.hasFocus, isTrue);
      final draftController = t.widget<TextField>(input).controller!;
      expect(draftController.text, longDraft);
      expect(draftController.selection,
          TextSelection.collapsed(offset: longDraft.length));
      await t.enterText(input, 'Short');
      await t.pumpAndSettle();
      expect(t.getSize(input).height, shortHeight);
      expect(controller.position.viewportDimension, shortViewport);
      expect(controller.offset, readerOffset);
      expect(
          controller.position.extentAfter, closeTo(distanceBeforeGrowth, .01));
      expect(controller.position.extentAfter, lessThan(shortViewport));
      expect(button, findsNothing);
      expect(editable.focusNode.hasFocus, isTrue);
      expect(draftController.text, 'Short');
      expect(
          draftController.selection, const TextSelection.collapsed(offset: 5));
      // Schedule an old metrics measurement, then replace its conversation.
      controller.jumpTo(0);
      await c.newSession(connection, 'other', '');
      await t.pumpAndSettle();
      expect(button, findsNothing);
      c.current!.messages.add(ChatMessage(role: 'model', content: 'Short'));
      c.select(original);
      await t.pumpAndSettle();
      controller.jumpTo(0);
      await t.pumpWidget(const SizedBox());
      await t.pump();
      expect(t.takeException(), isNull);
      c.dispose();
    });
  }
  testWidgets('latest chevron uses the exact current transcript threshold',
      (t) async {
    final c = ChatController(await makeStore());
    await c.load();
    final connection = {
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'https://example.com'
    };
    await c.addConnection(connection, '');
    await c.newSession(connection, 'small', '');
    c.current!.messages.addAll(List.generate(
        60,
        (i) => ChatMessage(
            role: 'model',
            content: 'History row $i with enough text to scroll.')));
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    final scroll = t.widget<ListView>(find.byType(ListView).first).controller!;
    final button = find.byTooltip('Jump to latest');
    for (final delta in [-1.0, 0.0, 1.0]) {
      scroll.jumpTo(scroll.position.maxScrollExtent -
          scroll.position.viewportDimension -
          delta);
      await t.pumpAndSettle();
      expect(button, delta > 0 ? findsOneWidget : findsNothing,
          reason: 'distance = viewport + $delta');
    }
    await t.tap(button);
    await t.pumpAndSettle();
    expect(scroll.position.extentAfter, 0);
    expect(button, findsNothing);
    scroll.jumpTo(0);
    await t.pumpAndSettle();
    Focus.of(t.element(find.byIcon(Icons.keyboard_arrow_down_rounded)))
        .requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(scroll.position.extentAfter, 0);
    expect(button, findsNothing);
    final long = c.current!;
    await c.newSession(connection, 'short', '');
    await t.pumpAndSettle();
    expect(button, findsNothing);
    c.current!.messages
        .add(ChatMessage(role: 'model', content: 'Short answer'));
    c.select(long);
    c.select(c.sessions.last);
    await t.pumpAndSettle();
    expect(button, findsNothing);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
