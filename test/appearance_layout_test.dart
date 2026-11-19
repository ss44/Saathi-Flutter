import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:saathi/main.dart';
import 'package:saathi/ui/chat_home.dart';
import 'appearance_surfaces_test.dart' show appearanceChatStore;

Future<void> tabTo(WidgetTester tester, Finder target) async {
  bool focused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    final targets = target.evaluate().toSet();
    var found = targets.contains(context);
    context.visitAncestorElements((element) {
      found = found || targets.contains(element);
      return !found;
    });
    return found;
  }

  for (var i = 0; i < 35 && !focused(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
  }
  expect(focused(), isTrue, reason: 'Appearance must be keyboard reachable');
}

void main() {
  for (final width in [360.0, 390.0]) {
    testWidgets('appearance is accessible at $width 2x text with keyboard',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final semantics = tester.ensureSemantics();
      try {
        PackageInfo.setMockInitialValues(
            appName: 'Saathi',
            packageName: 'test.saathi',
            version: '0.1.0',
            buildNumber: '1',
            buildSignature: '');
        final store = await appearanceChatStore();
        await tester.pumpWidget(SaathiApp(
            store: store,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!)));
        await tester.pumpAndSettle();
        final composer = find.byKey(const Key('composer'));
        await tester.enterText(composer, 'Draft remains');
        final textController = tester.widget<TextField>(composer).controller!;
        textController.selection =
            const TextSelection(baseOffset: 2, extentOffset: 5);
        final controller =
            tester.widget<ChatHome>(find.byType(ChatHome)).controller;
        final chat = controller.current;
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        final choice = find.byKey(const Key('appearance-choice'));
        await tabTo(tester, choice);
        final data = tester.getSemantics(choice).getSemanticsData();
        expect(data.label, contains('Appearance'));
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        expect(tester.getSize(choice).height, greaterThanOrEqualTo(48));
        for (final label in ['Dark', 'Light', 'System']) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(label).last);
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final expected = label == 'Dark' ? Brightness.dark : Brightness.light;
          tester.platformDispatcher.platformBrightnessTestValue =
              Brightness.light;
          await tester.pumpAndSettle();
          expect(Theme.of(tester.element(choice)).brightness, expected);
        }
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(tester.widget<ChatHome>(find.byType(ChatHome)).controller,
            same(controller));
        expect(controller.current, same(chat));
        expect(tester.widget<TextField>(composer).controller,
            same(textController));
        expect(textController.text, 'Draft remains');
        expect(textController.selection,
            const TextSelection(baseOffset: 2, extentOffset: 5));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
