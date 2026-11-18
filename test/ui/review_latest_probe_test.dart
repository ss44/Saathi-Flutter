import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/transcript_latest.dart';
import 'jump_latest_regression_test.dart' show variedChat;

Finder get transcript => find.descendant(
    of: find.byType(TranscriptLatest), matching: find.byType(ListView));
ScrollController scrollOf(WidgetTester t) =>
    t.widget<ListView>(transcript).controller!;

void main() {
  testWidgets('read-only retained history still reaches actual latest',
      (t) async {
    final c = await variedChat();
    final original = c.current!;
    await c.deleteConnection('a');
    expect(c.current, same(original));
    expect(c.readOnly, isTrue);
    expect(c.current!.messages.length, 60);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    final scroll = scrollOf(t);
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
    await t.tap(find.byTooltip('Jump to latest'));
    await t.pumpAndSettle();
    final after = scroll.position.extentAfter;
    await t.pumpWidget(const SizedBox());
    c.dispose();
    expect(after, lessThanOrEqualTo(1),
        reason: 'Read-only local history still exposes Jump to latest');
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('desktop resize and mouse latest at scale $scale', (t) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final ChatController c = await variedChat();
      await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ChatHome(controller: c),
      ));
      await t.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      final scroll = scrollOf(t);
      final input = find.byKey(const Key('composer'));
      await t.enterText(input, 'Preserve desktop draft');
      await t.pumpAndSettle();
      final editable = t.widget<EditableText>(
          find.descendant(of: input, matching: find.byType(EditableText)));
      await t.tap(find.byTooltip('Jump to latest'),
          kind: PointerDeviceKind.mouse);
      await t.pumpAndSettle();
      expect(editable.focusNode.hasFocus, isTrue);
      expect(scroll.position.extentAfter, lessThanOrEqualTo(1));
      await t.sendEventToBinding(PointerScrollEvent(
          position: t.getCenter(transcript),
          scrollDelta: Offset(0, -scroll.position.viewportDimension - 200),
          kind: PointerDeviceKind.mouse));
      await t.pumpAndSettle();
      expect(find.byTooltip('Jump to latest'), findsOneWidget);
      final offset = scroll.offset;
      t.view.physicalSize = const Size(1440, 800);
      await t.pumpAndSettle();
      expect(scroll.offset, offset);
      expect(find.byTooltip('Jump to latest'), findsOneWidget);
      expect(scroll.position.extentAfter,
          greaterThan(scroll.position.viewportDimension));
      t.view.physicalSize = const Size(390, 844);
      await t.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(scrollOf(t), same(scroll));
      expect(editable.focusNode.hasFocus, isTrue);
      expect(t.widget<TextField>(input).controller!.text,
          'Preserve desktop draft');
      expect(find.byTooltip('Jump to latest'), findsOneWidget);
      await t.tap(find.byTooltip('Jump to latest'));
      await t.pumpAndSettle();
      expect(scroll.position.extentAfter, lessThanOrEqualTo(1));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
