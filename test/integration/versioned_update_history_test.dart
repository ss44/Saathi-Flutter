import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/update_host.dart';
import 'package:saathi/updates/saathi_updates.dart';
import '../updates/saathi_updates_test.dart' show ReleaseFixture;

void main() {
  testWidgets(
      'a fresh check replaces repeated release metadata without a binary',
      (tester) async {
    final fixture = ReleaseFixture(version: '2026.47.4', build: 2);
    fixture.release['body'] =
        '<!-- saathi-changes:start -->\n- Recycled old notes\n<!-- saathi-changes:end -->';
    final controller = SaathiUpdateController(
        service:
            fixture.service(installed: UpdateVersion.parse('2026.47.4', 2)));
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.check(force: true));
    await tester.pumpWidget(
        MaterialApp(home: SaathiUpdatesPage(controller: controller)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('• Recycled old notes'), findsOneWidget);
    fixture.release['body'] =
        '<!-- saathi-changes:start -->\n- Corrected per-version history\n- <img src="https://evil.test">\n<!-- saathi-changes:end -->';
    await tester.runAsync(() => controller.check(force: true));
    await tester.pumpAndSettle();
    expect(find.text('• Corrected per-version history'), findsOneWidget);
    expect(find.text('• Recycled old notes'), findsNothing);
    expect(find.text('• <img src="https://evil.test">'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    for (final version in ['2026.47.4', '2026.47.3', '2026.47.2']) {
      expect(find.text(version), findsOneWidget);
    }
    expect(controller.offer, isNull);
    expect(controller.status, UpdateStatus.upToDate);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'App updates renders distinct real released history, not next notes',
      (tester) async {
    final fixture = ReleaseFixture();
    final controller = SaathiUpdateController(service: fixture.service());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        MaterialApp(home: SaathiUpdatesPage(controller: controller)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    for (final version in ['2026.47.4', '2026.47.3', '2026.47.2']) {
      expect(find.text(version), findsOneWidget);
    }
    const newest =
        '• Choose real Hermes models and their providers for new conversations.';
    const queued =
        '• Queue follow-up messages while a reply is in progress; they send in order after it finishes.';
    const search = '• Search conversations saved on this device.';
    for (final note in [newest, queued, search]) {
      expect(find.text(note), findsOneWidget);
    }
    expect(tester.getTopLeft(find.text(newest)).dy,
        lessThan(tester.getTopLeft(find.text('2026.47.3')).dy));
    expect(tester.getTopLeft(find.text(queued)).dy,
        lessThan(tester.getTopLeft(find.text('2026.47.2')).dy));
    expect(
        find.textContaining('instead of repeating older notes'), findsNothing);
    expect(find.textContaining('Discord'), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
