import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/main.dart';
import 'package:saathi/ui/chat_home.dart';
import 'appearance_surfaces_test.dart' show appearanceChatStore;

void main() {
  testWidgets(
      'desktop rail sidebar and embedded settings share live appearance',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(SaathiApp(store: await appearanceChatStore()));
    await tester.pumpAndSettle();
    final home = find.byType(ChatHome);
    final state = tester.state(home);
    final controller = tester.widget<ChatHome>(home).controller;
    final chat = controller.current;
    final input = find.byKey(const Key('composer'));
    await tester.enterText(input, 'Desktop draft');
    final text = tester.widget<TextField>(input).controller!;
    text.selection = const TextSelection(baseOffset: 2, extentOffset: 6);
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      final scheme = Theme.of(tester.element(home)).colorScheme;
      expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .backgroundColor,
          scheme.surfaceContainer);
      expect(tester.widget<Drawer>(find.byType(Drawer)).backgroundColor,
          scheme.surfaceContainerLow);
      expect(tester.state(home), same(state));
      expect(tester.widget<TextField>(input).controller, same(text));
    }
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final choice = find.byKey(const Key('appearance-choice'));
    await tester.tap(choice);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(choice)).brightness, Brightness.dark);
    expect(find.byTooltip('Connection settings'), findsNothing);
    await tester.tap(find.text('Chats'));
    await tester.pumpAndSettle();
    expect(tester.state(home), same(state));
    expect(tester.widget<ChatHome>(home).controller, same(controller));
    expect(controller.current, same(chat));
    expect(tester.widget<TextField>(input).controller, same(text));
    expect(text.text, 'Desktop draft');
    expect(text.selection, const TextSelection(baseOffset: 2, extentOffset: 6));
    expect(tester.takeException(), isNull);
  });
}
