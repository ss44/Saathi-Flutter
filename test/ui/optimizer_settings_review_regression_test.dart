import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const key = 'saathi.optimizer.v1';
const channel = MethodChannel('plugins.flutter.io/shared_preferences');
const old = OptimizerSelection(connectionId: 'source', model: 'old');
const candidate =
    OptimizerSelection(connectionId: 'source', model: 'candidate');
const later = OptimizerSelection(connectionId: 'source', model: 'later');

class Disk {
  final values = <String, Object>{};
  Future<bool> Function(int)? onWrite;
  int writes = 0;
  Future<SharedPreferences> open() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return Map<String, Object>.from(values);
      final args = call.arguments as Map;
      if (call.method.startsWith('set')) {
        values[args['key'] as String] = args['value'] as Object;
      } else if (call.method == 'remove') {
        values.remove(args['key']);
      }
      if (args['key'] == 'flutter.$key') {
        writes++;
        return onWrite == null ? true : await onWrite!(writes);
      }
      return true;
    });
    return SharedPreferences.getInstance();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SharedPreferences.setMockInitialValues({});
  });
  for (final throws in [false, true]) {
    test(
        'independent overlap guard spans failed write and compensation throw=$throws',
        () async {
      final disk = Disk();
      final prefs = await disk.open();
      final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
      final c = ChatController(store);
      await c.saveOptimizerSelection(old);
      final raw = prefs.get(key);
      final primary = Completer<bool>();
      final rollback = Completer<bool>();
      disk.onWrite = (n) async {
        if (n == 2) {
          final value = await primary.future;
          if (throws) throw PlatformException(code: 'independent-primary');
          return value;
        }
        if (n == 3) return rollback.future;
        return true;
      };
      final first = c.saveOptimizerSelection(candidate);
      final failed = expectLater(first, throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      expect(c.optimizerSettingsSaving, isTrue);
      expect(c.globalOptimizerSelection, old);
      await expectLater(c.saveOptimizerSelection(later), throwsStateError);
      expect(disk.writes, 2);
      primary.complete(false);
      await Future<void>.delayed(Duration.zero);
      expect(disk.writes, 3);
      expect(c.optimizerSettingsSaving, isTrue);
      await expectLater(c.saveOptimizerSelection(later), throwsStateError);
      expect(disk.writes, 3);
      rollback.complete(true);
      await failed;
      expect(c.optimizerSettingsSaving, isFalse);
      expect(c.globalOptimizerSelection, old);
      expect(prefs.get(key), raw);
      expect(disk.values['flutter.$key'], raw);
      final replacement = ChatController(store);
      expect(replacement.globalOptimizerSelection, old);
      final cold = ChatController(SaathiStore(
          preferences: await disk.open(), secrets: MemorySecrets()));
      expect(cold.globalOptimizerSelection, old);
      await c.saveOptimizerSelection(later);
      expect(c.globalOptimizerSelection, later);
      expect(
          jsonDecode(disk.values['flutter.$key'] as String)['global']['model'],
          'later');
      replacement.dispose();
      cold.dispose();
      c.dispose();
    });
    test('independent failed compensation never reports commit throw=$throws',
        () async {
      final disk = Disk();
      final prefs = await disk.open();
      final c = ChatController(
          SaathiStore(preferences: prefs, secrets: MemorySecrets()));
      await c.saveOptimizerSelection(old);
      final raw = prefs.get(key);
      disk.onWrite = (n) async {
        if (throws) throw PlatformException(code: 'independent-both-writes');
        return false;
      };
      await expectLater(c.saveOptimizerSelection(candidate), throwsA(anything));
      expect(c.globalOptimizerSelection, old);
      expect(c.optimizerSettingsSaving, isFalse);
      expect(prefs.get(key), raw);
      expect(disk.values['flutter.$key'], raw);
      c.dispose();
    });
  }

  testWidgets(
      'independent cancelled pending save must not pop the Settings route',
      (t) async {
    final disk = Disk();
    final prefs = await disk.open();
    final c = ChatController(
        SaathiStore(preferences: prefs, secrets: MemorySecrets()));
    await c.load();
    await c.addConnection({
      'id': 'source',
      'name': 'Source',
      'type': 'openai',
      'url': 'https://example.test'
    }, 'fixture');
    await c.newSession(c.connections.single, 'response', 'instructions');
    await c.saveOptimizerSelection(old, chat: c.current);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Chat prompt optimizer'), 200);
    await t.tap(find.text('Chat prompt optimizer'));
    await t.pumpAndSettle();
    final gate = Completer<bool>();
    disk.onWrite = (_) => gate.future;
    await t.tap(find.text('Inherit global setting'));
    await t.pump();
    expect(c.optimizerSettingsSaving, isTrue);
    await t.tap(find.text('Cancel'));
    await t.pump(const Duration(milliseconds: 10));
    gate.complete(true);
    await t.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget,
        reason: 'A completed save may close only its own still-current dialog');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
