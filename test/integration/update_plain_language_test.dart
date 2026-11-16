import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/update_host.dart';
import 'package:saathi/updates/saathi_updates.dart';
import '../updates/saathi_updates_test.dart' show ReleaseFixture;

class PendingCheckService extends SaathiUpdateService {
  PendingCheckService()
      : super(
          config: const UpdateConfig(owner: 'example', repo: 'saathi'),
          installed: UpdateVersion.parse('1.0.0', 1),
        );
  final pending = Completer<UpdateOffer?>();
  @override
  Future<UpdateOffer?> check() => pending.future;
}

void main() {
  testWidgets('checking disables actions and keeps expanded history',
      (t) async {
    final service = PendingCheckService();
    final controller = SaathiUpdateController(service: service);
    addTearDown(controller.dispose);
    final check = controller.check(force: true);
    await t.pumpWidget(
        MaterialApp(home: SaathiUpdatesPage(controller: controller)));
    await t.pump();
    expect(find.text('Checking for updates…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final button = t.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Check for updates'));
    expect(button.onPressed, isNull);
    expect(find.text("What's new"), findsOneWidget);
    service.pending.complete(null);
    await check;
    await t.pumpAndSettle();
    expect(find.text('You’re up to date.'), findsOneWidget);
  });

  testWidgets('install is primary and confirmation uses everyday words',
      (t) async {
    final fixture = ReleaseFixture();
    final controller = SaathiUpdateController(service: fixture.service());
    addTearDown(controller.dispose);
    await t.runAsync(() => controller.check(force: true));
    await t.pumpWidget(
        MaterialApp(home: SaathiUpdatesPage(controller: controller)));
    await t.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Install update'), findsOneWidget);
    expect(t.getTopLeft(find.text("What's new")).dy,
        greaterThan(t.getBottomLeft(find.text('Install update')).dy));
    await t.tap(find.text('Install update'));
    await t.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.textContaining('APK')),
        findsNothing);
    expect(find.descendant(of: dialog, matching: find.textContaining('verify')),
        findsNothing);
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining('Android will ask')),
        findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('downloading disables actions until the install handoff finishes',
      (t) async {
    final fixture = ReleaseFixture();
    final gate = Completer<bool>();
    final controller = SaathiUpdateController(
        service: fixture.service(), installer: (_) => gate.future);
    addTearDown(controller.dispose);
    await t.runAsync(() => controller.check(force: true));
    await t.pumpWidget(
        MaterialApp(home: SaathiUpdatesPage(controller: controller)));
    await t.pumpAndSettle();
    Future<void>? install;
    await t.runAsync(() async {
      install = controller.installAndroid(userConsented: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pump();
    expect(find.text('Downloading your update…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
        t
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Install update'))
            .onPressed,
        isNull);
    gate.complete(true);
    await t.runAsync(() => install!);
    await t.pumpAndSettle();
    expect(find.text('Follow Android’s prompts to finish installing.'),
        findsOneWidget);
    expect(find.textContaining('SHA-256'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
