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
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _key = 'saathi.optimizer.v1';
const _channel = MethodChannel('plugins.flutter.io/shared_preferences');

/// Separate the plugin's optimistic Dart cache from controlled durable data.
class _PreferenceDisk {
  final values = <String, Object>{};
  bool failNext = false, throws = false;

  Future<SharedPreferences> open() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'getAll') return Map<String, Object>.from(values);
      if (call.method.startsWith('set')) {
        values[args!['key'] as String] = args['value'] as Object;
        if (args['key'] == 'flutter.$_key' && failNext) {
          failNext = false;
          if (throws) throw PlatformException(code: 'fixture-write-failure');
          return false;
        }
      } else if (call.method == 'remove') {
        values.remove(args!['key']);
      }
      return true;
    });
    return SharedPreferences.getInstance();
  }
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    SharedPreferences.setMockInitialValues({});
  });

  for (final chatScope in [false, true]) {
    for (final throws in [false, true]) {
      testWidgets(
          'Settings failed save survives restart: chat=$chatScope throw=$throws',
          (t) async {
        final disk = _PreferenceDisk()..throws = throws;
        final preferences = await disk.open();
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'replacement'}
                ]
              }),
              200);
        });
        final store =
            SaathiStore(preferences: preferences, secrets: MemorySecrets());
        final c = ChatController(store,
            coreFactory: () => SaathiCore(client: client));
        await c.load();
        await c.addConnection({
          'id': 'source',
          'name': 'Source',
          'type': 'openai',
          'url': 'https://example.test'
        }, 'fixture-only');
        await c.newSession(c.connections.single, 'response', 'instructions');
        final chat = c.current!;
        const global =
            OptimizerSelection(connectionId: 'source', model: 'global');
        const local =
            OptimizerSelection(connectionId: 'source', model: 'local');
        await c.saveOptimizerSelection(global);
        await c.saveOptimizerSelection(local, chat: chat);
        final before = preferences.get(_key);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Settings'));
        await t.pumpAndSettle();
        final label =
            chatScope ? 'Chat prompt optimizer' : 'Global prompt optimizer';
        await t.scrollUntilVisible(find.text(label), 200);
        await t.tap(find.text(label));
        await t.pumpAndSettle();
        await t.tap(find.descendant(
            of: find.byType(AlertDialog), matching: find.text('Source')));
        for (var i = 0; i < 8; i++) {
          await t.pump();
          await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
        }
        await t.pumpAndSettle();
        disk.failNext = true;
        await t.tap(find.text('replacement'));
        await t.pumpAndSettle();
        expect(find.text('Could not save. Please try again.'), findsOneWidget);
        expect(c.globalOptimizerSelection, global);
        expect(c.optimizerOverride(chat), local);
        expect(preferences.get(_key), before);
        expect(disk.values['flutter.$_key'], before);
        final sameCache = ChatController(store);
        expect(sameCache.globalOptimizerSelection, global);
        expect(sameCache.optimizerOverride(chat), local);
        sameCache.dispose();
        final cold = ChatController(SaathiStore(
            preferences: await disk.open(), secrets: MemorySecrets()));
        expect(cold.globalOptimizerSelection, global);
        expect(cold.optimizerOverride(chat), local);
        cold.dispose();
        expect(chat.model, 'response');
        expect(chat.systemPrompt, 'instructions');
        expect(requests.map((r) => r.method), ['GET']);
        // Retry deliberately refreshes the catalog, but never starts inference.
        await t.tap(find.text('Catalog changed. Try again.'));
        for (var i = 0; i < 8; i++) {
          await t.pump();
          await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
        }
        await t.pumpAndSettle();
        await t.tap(find.text('replacement'));
        await t.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(
            chatScope
                ? c.optimizerOverride(chat)?.model
                : c.globalOptimizerSelection?.model,
            'replacement');
        expect(requests.map((r) => r.method), ['GET', 'GET']);
        await t.pumpWidget(const SizedBox.shrink());
        c.dispose();
        client.close();
      });
    }
  }

  for (final prior in <Object?>[
    null,
    <Object?>['prior'],
    true,
    7,
    1.5
  ]) {
    test('failed optimizer write restores exact raw preference $prior',
        () async {
      final disk = _PreferenceDisk();
      if (prior != null) disk.values['flutter.$_key'] = prior;
      final preferences = await disk.open();
      final c = ChatController(
          SaathiStore(preferences: preferences, secrets: MemorySecrets()));
      disk.failNext = true;
      await expectLater(
          c.saveOptimizerSelection(
              const OptimizerSelection(connectionId: 'source', model: 'new')),
          throwsStateError);
      expect(preferences.get(_key), prior);
      expect(disk.values['flutter.$_key'], prior);
      expect((await disk.open()).get(_key), prior);
      c.dispose();
    });
  }
}
