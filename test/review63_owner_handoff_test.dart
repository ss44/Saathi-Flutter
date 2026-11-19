import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/appearance.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  const key = 'flutter.${Appearance.preferenceKey}';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('real remounted app cannot lose a newer acknowledged appearance',
      (tester) async {
    final disk = <String, Object>{key: 'light'};
    final first = Completer<bool>();
    var writes = 0;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      final args = call.arguments as Map;
      writes++;
      if (writes == 1) return first.future;
      disk[args['key'] as String] = args['value'] as Object;
      return true;
    });
    final prefs = await SharedPreferences.getInstance();
    final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
    final choice = find.byKey(const Key('appearance-choice'));
    Future<void> choose(String label) async {
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(SaathiApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await choose('Dark');
    expect(tester.widget<DropdownButton<ThemeMode>>(choice).value,
        ThemeMode.light);
    expect(disk[key], 'light');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(SaathiApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await choose('System');
    expect(disk[key], 'system');
    first.complete(false);
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<ThemeMode>>(choice).value,
        ThemeMode.system);
    expect(find.textContaining('Could not save appearance'), findsNothing);
    debugPrint(
        'REVIEW63 actual remount selected=system persisted=${disk[key]} writes=$writes');
    expect(disk[key], 'system',
        reason:
            'Disposed app compensation overwrote replacement app successful UI choice');
  });

  test('replacement owner cannot publish unacknowledged old selection',
      () async {
    final disk = <String, Object>{key: 'light'};
    final first = Completer<bool>();
    var writes = 0;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      final args = call.arguments as Map;
      writes++;
      if (writes == 1 && !await first.future) return false;
      disk[args['key'] as String] = args['value'] as Object;
      return true;
    });
    final prefs = await SharedPreferences.getInstance();
    final old = Appearance(prefs);
    final pending = old.select(ThemeMode.dark);
    await Future<void>.delayed(Duration.zero);
    old.dispose();
    final replacement = Appearance(prefs);
    final beforeAck = replacement.mode;
    first.complete(false);
    await pending;
    debugPrint(
        'REVIEW63 replacement=$beforeAck durable=${disk[key]} cache=${prefs.get(Appearance.preferenceKey)}');
    replacement.dispose();
    expect(beforeAck, ThemeMode.light,
        reason:
            'Replacement owner must not publish optimistic cache as committed preference');
  });

  for (final throwing in [false, true]) {
    test(
        'old compensation cannot overwrite replacement commit throwing=$throwing',
        () async {
      final disk = <String, Object>{key: 'light'};
      final first = Completer<bool>();
      var writes = 0;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance =
          MethodChannelSharedPreferencesStore();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getAll') return Map<String, Object>.from(disk);
        final args = call.arguments as Map;
        writes++;
        if (writes == 1) {
          await first.future;
          if (throwing) throw PlatformException(code: 'delayed-write-failed');
          return false;
        }
        disk[args['key'] as String] = args['value'] as Object;
        return true;
      });
      final prefs = await SharedPreferences.getInstance();
      final old = Appearance(prefs);
      final pending = old.select(ThemeMode.dark);
      await Future<void>.delayed(Duration.zero);
      old.dispose();
      final replacement = Appearance(prefs);
      await replacement.select(ThemeMode.system);
      expect(replacement.mode, ThemeMode.system);
      expect(disk[key], 'system');
      first.complete(false);
      await pending;
      SharedPreferences.resetStatic();
      final cold = Appearance(await SharedPreferences.getInstance());
      debugPrint(
          'REVIEW63 replacement=${replacement.mode} error=${replacement.error} cache=${prefs.get(Appearance.preferenceKey)} disk=${disk[key]} cold=${cold.mode} writes=$writes');
      final persisted = disk[key];
      final coldMode = cold.mode;
      replacement.dispose();
      cold.dispose();
      expect(persisted, 'system',
          reason:
              'An older failed write must not compensate over a newer acknowledged selection');
      expect(coldMode, ThemeMode.system);
    });
  }
}
