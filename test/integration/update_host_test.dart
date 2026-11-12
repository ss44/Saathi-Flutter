import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/update_host.dart';
import 'package:saathi/updates/saathi_updates.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../updates/saathi_updates_test.dart' show ReleaseFixture;

void main() {
  testWidgets(
      'real Saathi app wires installed package metadata into update settings',
      (tester) async {
    PackageInfo.setMockInitialValues(
        appName: 'Saathi',
        packageName: 'io.github.ss44.saathi',
        version: '0.1.0',
        buildNumber: '1',
        buildSignature: '');
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    await tester.pumpWidget(SaathiApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Connection settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('App updates'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not configured'), findsOneWidget);
    expect(find.text('Saathi 0.1.0 · build 1'), findsOneWidget);
  });
  testWidgets(
      'available release is visible but opening it still requires confirmation',
      (tester) async {
    final fixture =
        ReleaseFixture(); // Synthetic release bytes, never a real published APK.
    var opened = 0;
    final controller = SaathiUpdateController(
        service: fixture.service(),
        openUrl: (_) async {
          opened++;
          return true;
        });
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.check(force: true));
    await tester.pumpWidget(SaathiUpdateHost(
        controller: controller,
        child: const MaterialApp(
            home: Scaffold(
                body: Column(children: [
          UpdateAvailabilityBanner(),
          UpdateSettingsButton()
        ])))));
    await tester.runAsync(() => controller.check());
    await tester.pumpAndSettle();
    expect(controller.status, UpdateStatus.available);
    expect(find.textContaining('1.1.0'), findsOneWidget);
    expect(opened, 0);
    await tester.tap(find.text('Review update'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Open releases'));
    await tester.tap(find.text('Open releases'));
    await tester.pumpAndSettle();
    expect(find.text('Open the release page?'), findsOneWidget);
    expect(opened, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    await tester.tap(find.text('Open releases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open releases').last);
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.textContaining('No update was installed'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  testWidgets('update settings clearly disclose an unconfigured release source',
      (tester) async {
    final controller = SaathiUpdateController(
        service: SaathiUpdateService(
            config: const UpdateConfig(),
            installed: UpdateVersion.parse('0.1.0', 1)));
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.check(force: true));
    await tester.pumpWidget(SaathiUpdateHost(
        controller: controller,
        child:
            const MaterialApp(home: Scaffold(body: UpdateSettingsButton()))));
    await tester.tap(find.byTooltip('App updates'));
    await tester.pumpAndSettle();
    expect(find.text('App updates'), findsOneWidget);
    expect(find.textContaining('not configured'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Check for updates'));
    expect(button.onPressed, isNull);
    expect(find.textContaining('0.1.0'), findsOneWidget);
  });
}
