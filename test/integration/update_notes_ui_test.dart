import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/update_host.dart';
import 'package:saathi/updates/saathi_updates.dart';
import '../updates/saathi_updates_test.dart' show ReleaseFixture;

void main() {
  for (final width in [390.0, 360.0]) {
    testWidgets('complete plain notes and consent at $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = ReleaseFixture(version: '2026.48.1', build: 3);
      final longNote = 'Long complete note ${'many words ' * 80}END';
      fixture.release['body'] =
          '<!-- saathi-changes:start -->\n- $longNote\n- <img src="https://evil.test"> [link](https://evil.test)\n<!-- saathi-changes:end -->';
      var installs = 0;
      final controller = SaathiUpdateController(
          service: fixture.service(),
          installer: (_) async {
            installs++;
            return true;
          });
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.check(force: true));
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(width == 360 ? 2 : 1)),
              child: child!),
          home: SaathiUpdatesPage(controller: controller)));
      await tester.pumpAndSettle();
      expect(find.text('Install update'), findsOneWidget);
      expect(find.textContaining('build '), findsNothing);
      expect(find.textContaining('SHA'), findsNothing);
      expect(find.textContaining('six hours'), findsNothing);
      await tester.ensureVisible(find.text('Install update'));
      await tester.tap(find.text('Install update'));
      await tester.pumpAndSettle();
      expect(installs, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(installs, 0);
      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(find.text('• $longNote'), findsOneWidget);
      final text = tester.widget<Text>(find.text('• $longNote'));
      expect(text.maxLines, isNull);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(tester.takeException(), isNull);
      await tester
          .runAsync(() => controller.installAndroid(userConsented: true));
      await tester.pumpAndSettle();
      expect(installs, 1);
      expect(controller.status, UpdateStatus.handedOff);
      expect(find.text('Follow Android’s prompts to finish installing.'),
          findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
  testWidgets('current and error keep released history', (tester) async {
    final fixture = ReleaseFixture();
    final controller = SaathiUpdateController(
        service: fixture.service(installed: UpdateVersion.parse('1.1.0', 2)));
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.check(force: true));
    await tester.pumpWidget(
        MaterialApp(home: SaathiUpdatesPage(controller: controller)));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('You’re up to date.'), findsOneWidget);
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('2026.47.1'), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('\n'));
    expect(find.textContaining('A simpler App updates screen'), findsNothing);
    fixture.responseOverride = (_) => throw Exception('offline');
    await tester.runAsync(() => controller.check(force: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('Try again later'), findsOneWidget);
    expect(find.text('2026.47.1'), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join('\n'));
  });
}
