import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const channel = MethodChannel('plugins.flutter.io/shared_preferences');
const rawKey = 'flutter.${Appearance.preferenceKey}';

class HandoffStore {
  final disk = <String, Object>{rawKey: 'light'};
  int writes = 0;
  Future<bool> Function(int, Map)? onWrite;

  Future<SharedPreferences> open() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      final args = call.arguments as Map;
      writes++;
      if (onWrite != null) return onWrite!(writes, args);
      return mutate(args);
    });
    return SharedPreferences.getInstance();
  }

  bool mutate(Map args) {
    if (args.containsKey('value')) {
      disk[args['key'] as String] = args['value'] as Object;
    } else {
      disk.remove(args['key']);
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SharedPreferences.setMockInitialValues({});
  });

  test(
      'accepted success after disposal updates replacement without new selection',
      () async {
    final fixture = HandoffStore();
    final gate = Completer<void>();
    fixture.onWrite = (number, args) async {
      if (number == 1) await gate.future;
      return fixture.mutate(args);
    };
    final prefs = await fixture.open();
    final old = Appearance(prefs);
    final pending = old.select(ThemeMode.dark);
    old.dispose();
    final replacement = Appearance(prefs);
    addTearDown(replacement.dispose);
    var notifications = 0;
    replacement.addListener(() => notifications++);
    expect(replacement.mode, ThemeMode.light);
    gate.complete();
    await pending;
    expect(replacement.mode, ThemeMode.dark);
    expect(notifications, greaterThan(0));
    expect(fixture.disk[rawKey], 'dark');
    expect(prefs.get(Appearance.preferenceKey), 'dark');
    expect(fixture.writes, 1);
  });

  for (final sameChoice in [false, true]) {
    test(
        'late old success cannot replace newer acknowledged choice same=$sameChoice',
        () async {
      final fixture = HandoffStore();
      final gate = Completer<void>();
      fixture.onWrite = (number, args) async {
        if (number == 1) await gate.future;
        return fixture.mutate(args);
      };
      final prefs = await fixture.open();
      final old = Appearance(prefs);
      final pending = old.select(ThemeMode.dark);
      old.dispose();
      final replacement = Appearance(prefs);
      addTearDown(replacement.dispose);
      final choice = sameChoice ? ThemeMode.light : ThemeMode.system;
      await replacement.select(choice);
      expect(fixture.disk[rawKey], choice.name);
      gate.complete();
      await pending;
      expect(replacement.mode, choice);
      expect(replacement.error, isNull);
      expect(fixture.disk[rawKey], choice.name);
      expect(prefs.get(Appearance.preferenceKey), choice.name);
      SharedPreferences.resetStatic();
      final cold = Appearance(await SharedPreferences.getInstance());
      expect(cold.mode, choice);
      cold.dispose();
    });
  }

  for (final throwing in [false, true]) {
    test(
        'newer failed selection does not discard accepted older success throw=$throwing',
        () async {
      final fixture = HandoffStore();
      final gate = Completer<void>();
      fixture.onWrite = (number, args) async {
        if (number == 1) await gate.future;
        fixture.mutate(args);
        if (number == 2) {
          if (throwing) throw PlatformException(code: 'newer-failed');
          return false;
        }
        return true;
      };
      final prefs = await fixture.open();
      final old = Appearance(prefs);
      final pending = old.select(ThemeMode.dark);
      old.dispose();
      final replacement = Appearance(prefs);
      addTearDown(replacement.dispose);
      await replacement.select(ThemeMode.system);
      expect(replacement.mode, ThemeMode.light);
      expect(replacement.error, isNotNull);
      expect(fixture.disk[rawKey], 'light');
      gate.complete();
      await pending;
      expect(replacement.mode, ThemeMode.dark);
      expect(prefs.get(Appearance.preferenceKey), 'dark');
      expect(fixture.disk[rawKey], 'dark');
    });

    test(
        'replacement success during old compensation is reasserted throw=$throwing',
        () async {
      final fixture = HandoffStore();
      final entered = Completer<void>();
      final restore = Completer<void>();
      fixture.onWrite = (number, args) async {
        if (number == 2) {
          entered.complete();
          await restore.future;
        }
        fixture.mutate(args);
        if (number == 1) {
          if (throwing) throw PlatformException(code: 'old-failed');
          return false;
        }
        return true;
      };
      final prefs = await fixture.open();
      final old = Appearance(prefs);
      final pending = old.select(ThemeMode.dark);
      await entered.future;
      old.dispose();
      final replacement = Appearance(prefs);
      addTearDown(replacement.dispose);
      final newer = replacement.select(ThemeMode.system);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.disk[rawKey], 'system');
      restore.complete();
      await Future.wait([pending, newer]);
      expect(replacement.mode, ThemeMode.system);
      expect(replacement.error, isNull);
      expect(fixture.disk[rawKey], 'system');
      expect(prefs.get(Appearance.preferenceKey), 'system');
      expect(fixture.writes, 4);
    });

    test(
        'failed old repair remains visible across replacement and same-choice retry throw=$throwing',
        () async {
      final fixture = HandoffStore();
      final gate = Completer<void>();
      fixture.onWrite = (number, args) async {
        if (number == 1) await gate.future;
        if (number == 3) {
          if (throwing) throw PlatformException(code: 'repair-failed');
          return false; // No durable mutation on failed compensation.
        }
        fixture.mutate(args);
        if (number == 1) {
          if (throwing) {
            throw PlatformException(code: 'old-mutated-then-failed');
          }
          return false;
        }
        return true;
      };
      final prefs = await fixture.open();
      final old = Appearance(prefs);
      final pending = old.select(ThemeMode.dark);
      old.dispose();
      final replacement = Appearance(prefs);
      await replacement.select(ThemeMode.system);
      gate.complete();
      await pending;
      expect(replacement.mode, ThemeMode.system);
      expect(replacement.error, contains('could change after restarting'));
      expect(prefs.get(Appearance.preferenceKey), 'system');
      expect(fixture.disk[rawKey], 'dark');
      replacement.dispose();
      final third = Appearance(prefs);
      addTearDown(third.dispose);
      expect(third.mode, ThemeMode.system);
      expect(third.error, contains('could change after restarting'));
      SharedPreferences.resetStatic();
      final uncertainCold = Appearance(await SharedPreferences.getInstance());
      expect(uncertainCold.mode, ThemeMode.dark);
      uncertainCold.dispose();
      await third.select(ThemeMode.system);
      expect(third.error, isNull);
      expect(prefs.get(Appearance.preferenceKey), 'system');
      expect(fixture.disk[rawKey], 'system');
      SharedPreferences.resetStatic();
      final repairedCold = Appearance(await SharedPreferences.getInstance());
      expect(repairedCold.mode, ThemeMode.system);
      repairedCold.dispose();
    });
  }
}
