import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
  testWidgets(
      'pending selector keeps committed value and disables duplicate input',
      (tester) async {
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    final disk = <String, Object>{'flutter.saathi.appearance.v1': 'light'};
    final response = Completer<bool>();
    var writes = 0;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      writes++;
      final args = call.arguments as Map;
      if (writes == 1 && !await response.future) return false;
      disk[args['key'] as String] = args['value'] as Object;
      return true;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      SharedPreferences.setMockInitialValues({});
    });
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(SaathiApp(
        store:
            SaathiStore(preferences: preferences, secrets: MemorySecrets())));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final choice = find.byKey(const Key('appearance-choice'));
    await tester.tap(choice);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(tester.widget<DropdownButton<ThemeMode>>(choice).value,
        ThemeMode.light);
    expect(tester.widget<DropdownButton<ThemeMode>>(choice).onChanged, isNull);
    expect(Theme.of(tester.element(choice)).brightness, Brightness.light);
    expect(find.text('Saving appearance…'), findsOneWidget);
    expect(preferences.get('saathi.appearance.v1'),
        'dark'); // Optimistic cache only.
    expect(disk['flutter.saathi.appearance.v1'], 'light');
    response.complete(false);
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<ThemeMode>>(choice).value,
        ThemeMode.light);
    expect(
        tester.widget<DropdownButton<ThemeMode>>(choice).onChanged, isNotNull);
    expect(Theme.of(tester.element(choice)).brightness, Brightness.light);
    expect(find.textContaining('Could not save appearance'), findsOneWidget);
    expect(preferences.get('saathi.appearance.v1'), 'light');
    expect(disk['flutter.saathi.appearance.v1'], 'light');
  });
  for (final failure in ['false', 'throw']) {
    for (final prior in [null, 'light']) {
      testWidgets(
          '$failure platform write retains prior $prior in UI cache and restart',
          (tester) async {
        const channel = MethodChannel('plugins.flutter.io/shared_preferences');
        final disk = <String, Object>{
          if (prior != null) 'flutter.saathi.appearance.v1': prior,
        };
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance =
            MethodChannelSharedPreferencesStore();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
            (call) async {
          if (call.method == 'getAll') return Map<String, Object>.from(disk);
          if (failure == 'throw') {
            throw PlatformException(code: 'fixture-write');
          }
          return false;
        });
        addTearDown(() {
          tester.binding.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          SharedPreferences.setMockInitialValues({});
        });
        final prefs = await SharedPreferences.getInstance();
        final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await tester.pumpWidget(SaathiApp(store: store));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('appearance-choice')));
        await tester.tap(find.byKey(const Key('appearance-choice')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dark').last);
        await tester.pumpAndSettle();
        expect(
            find.textContaining('Could not save appearance'), findsOneWidget);
        expect(
            tester
                .widget<DropdownButton<ThemeMode>>(
                    find.byType(DropdownButton<ThemeMode>))
                .value,
            prior == null ? ThemeMode.system : ThemeMode.light);
        expect(prefs.get('saathi.appearance.v1'), prior);
        expect(disk['flutter.saathi.appearance.v1'], prior);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(SaathiApp(store: store));
        await tester.pumpAndSettle();
        expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
            Brightness.light);
        await tester.pumpWidget(const SizedBox());
        SharedPreferences.resetStatic();
        final reopened = SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets());
        await tester.pumpWidget(SaathiApp(store: reopened));
        await tester.pumpAndSettle();
        expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
            Brightness.light);
      });
    }
  }

  for (final invalid in <Object>[
    'unknown',
    '',
    true,
    7,
    0.5,
    ['dark']
  ]) {
    testWidgets('invalid preference $invalid follows live System',
        (tester) async {
      SharedPreferences.setMockInitialValues({'saathi.appearance.v1': invalid});
      final store = SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets());
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(SaathiApp(store: store));
      await tester.pumpAndSettle();
      for (final value in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = value;
        await tester.pumpAndSettle();
        expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
            value);
      }
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<DropdownButton<ThemeMode>>(
                  find.byType(DropdownButton<ThemeMode>))
              .value,
          ThemeMode.system);
    });
  }

  testWidgets('settings overrides persist and can return to System',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    Future<void> choose(String label) async {
      await tester.ensureVisible(find.byKey(const Key('appearance-choice')));
      await tester.tap(find.byKey(const Key('appearance-choice')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    Brightness brightness() =>
        Theme.of(tester.element(find.byType(Scaffold).last)).brightness;
    await tester.pumpWidget(SaathiApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    await choose('Light');
    expect(brightness(), Brightness.light);
    for (final os in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = os;
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
    }
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.resetStatic();
    final lightStore = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    await tester.pumpWidget(SaathiApp(store: lightStore));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    await choose('Dark');
    expect(brightness(), Brightness.dark);
    for (final os in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = os;
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.dark);
    }
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.resetStatic();
    final darkStore = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    await tester.pumpWidget(SaathiApp(store: darkStore));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await choose('System');
    expect(brightness(), Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.resetStatic();
    final systemStore = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    await tester.pumpWidget(SaathiApp(store: systemStore));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
  });

  testWidgets('unconfigured app follows live system brightness',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(SaathiApp(store: store));
    await tester.pumpAndSettle();
    Brightness brightness() =>
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness;
    expect(brightness(), Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
  });
}
