import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'prompt_optimizer_acceptance_test.dart' as fixture;
import 'optimizer_settings_driver.dart';

/// Real plugin cache, independently controlled durable platform storage.
class PreferenceDisk {
  static const key = 'saathi.optimizer.v1';
  static const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  final values = <String, Object>{};
  String? failure;
  bool mutateBeforeFailure = false;
  int failuresRemaining = 1;

  void install() {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') return Map<String, Object>.from(values);
      final args = call.arguments as Map;
      final key = args['key'] as String;
      final fail = key == 'flutter.${PreferenceDisk.key}' ? failure : null;
      if (fail != null && --failuresRemaining <= 0) failure = null;
      if (fail == null || mutateBeforeFailure) {
        if (call.method == 'remove') {
          values.remove(key);
        } else {
          values[key] = args['value'] as Object;
        }
      }
      if (fail == 'throw') throw PlatformException(code: 'write_failed');
      return fail == null;
    });
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SharedPreferences.resetStatic();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final failure in ['false', 'throw']) {
    test(
        'failed $failure compensation reports uncertain storage, not a restored setting',
        () async {
      final disk = PreferenceDisk()..install();
      addTearDown(disk.dispose);
      final preferences = await SharedPreferences.getInstance();
      final c = ChatController(
          SaathiStore(preferences: preferences, secrets: MemorySecrets()));
      const previous =
          OptimizerSelection(connectionId: 'direct', model: 'previous');
      const replacement =
          OptimizerSelection(connectionId: 'direct', model: 'replacement');
      await c.saveOptimizerSelection(previous);
      disk.failure = failure;
      disk.failuresRemaining = 2;
      await expectLater(c.saveOptimizerSelection(replacement),
          throwsA(isA<StorageRecoveryException>()));
      expect(c.globalOptimizerSelection, previous);
      final replacementOwner = ChatController(c.store);
      expect(replacementOwner.globalOptimizerSelection, previous);
      replacementOwner.dispose();
      await c.saveOptimizerSelection(replacement);
      expect(c.globalOptimizerSelection, replacement);
      c.dispose();
    });
  }
  for (final raw in <Object?>[
    null,
    true,
    7,
    1.5,
    <Object?>['old'],
    '{broken'
  ]) {
    test('failed initial/recovery write preserves raw $raw and permits retry',
        () async {
      final disk = PreferenceDisk()..install();
      addTearDown(disk.dispose);
      if (raw != null) disk.values['flutter.${PreferenceDisk.key}'] = raw;
      final preferences = await SharedPreferences.getInstance();
      final c = ChatController(
          SaathiStore(preferences: preferences, secrets: MemorySecrets()));
      expect(c.globalOptimizerSelection, isNull);
      const choice =
          OptimizerSelection(connectionId: 'direct', model: 'chosen');
      disk.failure = 'throw';
      disk.mutateBeforeFailure = true;
      await expectLater(c.saveOptimizerSelection(choice), throwsA(anything));
      expect(preferences.get(PreferenceDisk.key), raw);
      expect(disk.values['flutter.${PreferenceDisk.key}'], raw);
      SharedPreferences.resetStatic();
      expect(
          (await SharedPreferences.getInstance()).get(PreferenceDisk.key), raw);
      await c.saveOptimizerSelection(choice);
      expect(c.globalOptimizerSelection, choice);
      c.dispose();
    });
  }
  for (final scope in ['global', 'override', 'inherit']) {
    for (final failure in [
      'false',
      'throw',
      'rollback false',
      'rollback throw'
    ]) {
      for (final mutate in [false, true]) {
        testWidgets(
            '$scope $failure (disk mutated=$mutate) keeps committed choice through cold restart',
            (tester) async {
          final disk = PreferenceDisk()..install();
          addTearDown(disk.dispose);
          final preferences = await SharedPreferences.getInstance();
          final store =
              SaathiStore(preferences: preferences, secrets: MemorySecrets());
          final c = ChatController(store,
              coreFactory: () => SaathiCore(
                  client: MockClient((_) async => http.Response(
                      jsonEncode({
                        'data': [
                          {'id': 'replacement'}
                        ]
                      }),
                      200))));
          await c.load();
          await c.addConnection({
            'id': 'direct',
            'name': 'Direct',
            'type': 'openai',
            'url': 'http://localhost:9999'
          }, 'fixture');
          await c.newSession(c.connections.single, 'reply-only', '');
          final chat = c.current!;
          const global =
              OptimizerSelection(connectionId: 'direct', model: 'global');
          const local =
              OptimizerSelection(connectionId: 'direct', model: 'local');
          await c.saveOptimizerSelection(global);
          if (scope != 'global') {
            await c.saveOptimizerSelection(local, chat: chat);
          }
          final before = preferences.get(PreferenceDisk.key);
          disk.failure = failure.endsWith('throw') ? 'throw' : 'false';
          disk.failuresRemaining = failure.startsWith('rollback') ? 2 : 1;
          disk.mutateBeforeFailure = mutate;
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pumpWidget(MaterialApp(
              home: scope == 'global'
                  ? ConnectionsPage(controller: c)
                  : ChatHome(controller: c)));
          await openOptimizerSettings(tester, chat: scope != 'global');
          if (scope == 'inherit') {
            await tester.tap(find.text('Inherit global setting'));
          } else {
            await tester.tap(find.descendant(
                of: find.byType(AlertDialog), matching: find.text('Direct')));
            await fixture.flush(tester);
            await tester.tap(find.text('replacement'));
          }
          await tester.pumpAndSettle();
          expect(
              find.text(failure.startsWith('rollback')
                  ? 'Could not confirm storage recovery. Choose and save a destination again before restarting.'
                  : 'Could not save. Please try again.'),
              findsOneWidget);
          expect(
              c.optimizerSelection(chat), scope == 'global' ? global : local);
          expect(c.current!.model, 'reply-only');
          expect(preferences.get(PreferenceDisk.key), before,
              reason: 'optimistic plugin cache must roll back');
          expect(disk.values['flutter.${PreferenceDisk.key}'], before,
              reason: 'durable prior bytes must survive');
          final sameCacheOwner = ChatController(store);
          expect(sameCacheOwner.optimizerSelection(chat),
              scope == 'global' ? global : local);
          sameCacheOwner.dispose();
          await tester.pumpWidget(const SizedBox());
          c.dispose();
          SharedPreferences.resetStatic();
          final cold = ChatController(SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: MemorySecrets()));
          await cold.load();
          expect(cold.optimizerSelection(cold.sessions.single),
              scope == 'global' ? global : local);
          expect(cold.sessions.single.model, 'reply-only');
          cold.dispose();
        });
      }
    }
  }
}
