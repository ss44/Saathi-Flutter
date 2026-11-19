import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  for (final failsByThrowing in [false, true]) {
    testWidgets(
        'actual selector repairs unconfirmed rollback throwing=$failsByThrowing',
        (tester) async {
      const channel = MethodChannel('plugins.flutter.io/shared_preferences');
      const rawKey = 'flutter.${Appearance.preferenceKey}';
      final disk = <String, Object>{rawKey: 'light'};
      var writes = 0;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance =
          MethodChannelSharedPreferencesStore();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        if (call.method == 'getAll') return Map<String, Object>.from(disk);
        writes++;
        final args = call.arguments as Map;
        if (writes == 2) return false;
        if (call.method == 'remove') {
          disk.remove(args['key']);
        } else {
          disk[args['key'] as String] = args['value'] as Object;
        }
        if (writes == 1) {
          if (failsByThrowing) throw PlatformException(code: 'mutated-failure');
          return false;
        }
        return true;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        SharedPreferences.setMockInitialValues({});
        tester.platformDispatcher.clearPlatformBrightnessTestValue();
      });
      final prefs = await SharedPreferences.getInstance();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpWidget(SaathiApp(
          store: SaathiStore(preferences: prefs, secrets: MemorySecrets())));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      final choice = find.byKey(const Key('appearance-choice'));
      Future<void> choose(String label) async {
        await tester.ensureVisible(choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await choose('Dark');
      expect(writes, 2);
      expect(tester.widget<DropdownButton<ThemeMode>>(choice).value,
          ThemeMode.light);
      expect(Theme.of(tester.element(choice)).brightness, Brightness.light);
      expect(prefs.get(Appearance.preferenceKey), 'light');
      expect(disk[rawKey], 'dark');
      expect(
          find.textContaining('could change after restarting'), findsOneWidget);
      // Returning to Settings retains honest error and permits same-value repair.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('could change after restarting'), findsOneWidget);
      await choose('Light');
      expect(writes, 3);
      expect(disk[rawKey], 'light');
      expect(prefs.get(Appearance.preferenceKey), 'light');
      expect(find.textContaining('Could not save appearance'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      SharedPreferences.resetStatic();
      final cold = await SharedPreferences.getInstance();
      expect(cold.get(Appearance.preferenceKey), 'light');
      await tester.pumpWidget(SaathiApp(
          store: SaathiStore(preferences: cold, secrets: MemorySecrets())));
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
          Brightness.light);
      expect(tester.takeException(), isNull);
    });
  }
}
