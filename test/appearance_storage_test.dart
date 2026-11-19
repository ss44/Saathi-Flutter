import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    SharedPreferences.setMockInitialValues({});
  });

  for (final failure in ['false', 'throw']) {
    for (final prior in <Object?>[
      null,
      'light',
      true,
      3,
      0.5,
      ['dark']
    ]) {
      test('$failure after platform mutation compensates exact prior $prior',
          () async {
        final disk = <String, Object>{
          if (prior != null) 'flutter.${Appearance.preferenceKey}': prior
        };
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance =
            MethodChannelSharedPreferencesStore();
        var first = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAll') return Map<String, Object>.from(disk);
          final args = call.arguments as Map;
          if (call.method == 'remove') {
            disk.remove(args['key']);
          } else {
            disk[args['key'] as String] = args['value'] as Object;
          }
          if (first) {
            first = false;
            if (failure == 'false') return false;
            throw PlatformException(code: 'fixture-post-write-failure');
          }
          return true;
        });
        final preferences = await SharedPreferences.getInstance();
        final appearance = Appearance(preferences);
        final mode = appearance.mode;
        await appearance.select(ThemeMode.dark);
        expect(appearance.mode, mode);
        expect(appearance.saving, isFalse);
        expect(appearance.error, isNotNull);
        expect(preferences.get(Appearance.preferenceKey), prior);
        expect(disk['flutter.${Appearance.preferenceKey}'], prior);
        final replacement = Appearance(preferences);
        expect(replacement.mode, mode);
        appearance.dispose();
        replacement.dispose();
        SharedPreferences.resetStatic();
        final reopened = Appearance(await SharedPreferences.getInstance());
        expect(reopened.mode, mode);
        reopened.dispose();
      });
    }
  }

  test(
      'failed compensation discloses restart uncertainty and can repair prior choice',
      () async {
    final disk = <String, Object>{};
    var writes = 0;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      final args = call.arguments as Map;
      writes++;
      if (writes == 2) return false; // Compensation fails before mutation.
      if (call.method == 'remove') {
        disk.remove(args['key']);
      } else {
        disk[args['key'] as String] = args['value'] as Object;
      }
      if (writes == 1) throw PlatformException(code: 'mutated-before-throw');
      return true;
    });
    final preferences = await SharedPreferences.getInstance();
    final appearance = Appearance(preferences);
    await appearance.select(ThemeMode.dark);
    expect(appearance.mode, ThemeMode.system);
    expect(preferences.get(Appearance.preferenceKey), isNull);
    expect(disk['flutter.${Appearance.preferenceKey}'], 'dark');
    expect(appearance.error, contains('restarting'));
    final replacement = Appearance(preferences);
    expect(replacement.mode, ThemeMode.system);
    replacement.dispose();
    // Cold reload truthfully reflects the unconfirmed backing-store state.
    SharedPreferences.resetStatic();
    final cold = Appearance(await SharedPreferences.getInstance());
    expect(cold.mode, ThemeMode.dark);
    cold.dispose();
    // Selecting the still-active prior choice must repair storage, not no-op.
    await appearance.select(ThemeMode.system);
    expect(writes, 3);
    expect(appearance.error, isNull);
    expect(disk['flutter.${Appearance.preferenceKey}'], 'system');
    appearance.dispose();
  });

  test('pending save publishes only after acknowledgement and rejects reentry',
      () async {
    final response = Completer<bool>();
    var writes = 0;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return <String, Object>{};
      writes++;
      return response.future;
    });
    final preferences = await SharedPreferences.getInstance();
    final appearance = Appearance(preferences);
    await appearance.select(ThemeMode.system);
    expect(writes, 0);
    final pending = appearance.select(ThemeMode.dark);
    await Future<void>.delayed(Duration.zero);
    expect(appearance.saving, isTrue);
    expect(appearance.mode, ThemeMode.system);
    await appearance.select(ThemeMode.light);
    expect(writes, 1);
    response.complete(true);
    await pending;
    expect(appearance.mode, ThemeMode.dark);
    expect(appearance.error, isNull);
    appearance.dispose();
    await appearance.select(ThemeMode.light);
    expect(writes, 1);
  });

  test('accepted save settles safely after owner disposal', () async {
    final response = Completer<bool>();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return <String, Object>{};
      return response.future;
    });
    final appearance = Appearance(await SharedPreferences.getInstance());
    final pending = appearance.select(ThemeMode.dark);
    appearance.dispose();
    response.complete(true);
    await pending;
  });
}
