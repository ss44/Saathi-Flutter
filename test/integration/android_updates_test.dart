import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/update_host.dart';
import 'package:saathi/updates/saathi_updates.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../updates/saathi_updates_test.dart' show ReleaseFixture;

void main() {
  for (final keyboard in [0.0, 240.0]) {
    testWidgets(
        'Android update banner and settings fit 360px/2x/keyboard $keyboard',
        (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final chat = ChatController(SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets()));
      await chat.load();
      final fixture = ReleaseFixture(); // Synthetic bytes, not a published APK.
      fixture.release['body'] = '<!-- saathi-changes:start -->\n'
          '- Reopen existing conversations safely.\n'
          '<!-- saathi-changes:end -->';
      var installs = 0;
      final updates = SaathiUpdateController(
          service: fixture.service(),
          installer: (verified) async {
            expect(verified.bytes, fixture.apk);
            installs++;
            return true;
          });
      addTearDown(chat.dispose);
      addTearDown(updates.dispose);
      await tester.runAsync(() => updates.check(force: true));
      final metadataRequests = fixture.requests;
      await tester.pumpWidget(SaathiUpdateHost(
          controller: updates,
          child: MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(2),
                      viewInsets: EdgeInsets.only(bottom: keyboard)),
                  child: child!),
              home: ChatHome(controller: chat))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Review update').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('App updates'), 180,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('App updates'));
      await tester.pumpAndSettle();
      expect(find.text('Current version: 1.0.0'), findsOneWidget);
      expect(installs, 0);
      expect(fixture.requests, metadataRequests);
      await tester.ensureVisible(find.text('Install update'));
      await tester.tap(find.text('Install update'));
      await tester.pumpAndSettle();
      expect(find.text('Download this update?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(installs, 0);
      expect(fixture.requests, metadataRequests);
      await tester.scrollUntilVisible(
          find.text('• Reopen existing conversations safely.'), 160,
          scrollable: find.byType(Scrollable).first);
      expect(
          find.text('• Reopen existing conversations safely.'), findsOneWidget);
      await tester.ensureVisible(find.text('Install update'));
      await tester.tap(find.text('Install update'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(installs, 1);
      expect(fixture.requests, metadataRequests + 1);
      expect(updates.status, UpdateStatus.handedOff);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
