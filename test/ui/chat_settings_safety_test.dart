import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

import 'controller_http_test.dart' show makeStore;

Future<void> showPanel(WidgetTester t, ChatController c) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
  await t.pumpAndSettle();
  await t.tap(find.byTooltip('Chat settings'));
  await t.pumpAndSettle();
}

Future<void> setupChat(ChatController c) async {
  await c.load();
  await c.addConnection({
    'id': 'a',
    'name': 'Original',
    'type': 'openai',
    'url': 'https://example.com'
  }, '');
  await c.newSession(c.connections.single, 'original', 'Original instructions');
}

void main() {
  for (final throwsWrite in [false, true]) {
    for (final priorValue in [false, true]) {
      testWidgets(
          'failed settings save preserves cache and cold disk: throw=$throwsWrite prior=$priorValue',
          (t) async {
        const channel = MethodChannel('plugins.flutter.io/shared_preferences');
        final disk = <String, Object>{};
        var failNext = false;
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance =
            MethodChannelSharedPreferencesStore();
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
            (call) async {
          final args = call.arguments as Map?;
          if (call.method == 'getAll') return Map<String, Object>.from(disk);
          if (call.method.startsWith('set')) {
            disk[args!['key'] as String] = args['value'] as Object;
            if (args['key'] == 'flutter.${OrganizationStorage.key}' &&
                failNext) {
              failNext = false;
              if (throwsWrite) {
                throw PlatformException(code: 'controlled-write');
              }
              return false;
            }
          } else if (call.method == 'remove') {
            disk.remove(args!['key']);
          }
          return true;
        });
        addTearDown(() {
          t.binding.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          SharedPreferences.setMockInitialValues({});
        });
        final store = SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets());
        final c = ChatController(store);
        await setupChat(c);
        if (priorValue) {
          await c.saveChatSettings(c.current!,
              originalConnection: c.connections.single,
              selection: c.selectionGeneration,
              model: 'committed',
              instructions: 'Committed instructions',
              personaId: null);
        }
        final oldModel = c.replyModel(c.current!);
        final oldRaw = store.preferences.getString(OrganizationStorage.key);
        await showPanel(t, c);
        await t.enterText(
            find.byKey(const Key('chat-reply-model')), 'failed-candidate');
        await t.enterText(
            find.byKey(const Key('chat-instructions')), 'Failed instructions');
        failNext = true;
        await t.ensureVisible(find.text('Save'));
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(find.textContaining('Chat settings were not saved'),
            findsOneWidget);
        expect(c.replyModel(c.current!), oldModel);
        expect(store.preferences.getString(OrganizationStorage.key), oldRaw);
        expect(disk['flutter.${OrganizationStorage.key}'], oldRaw);
        expect(c.organization.hasUnsavedChanges, isFalse);
        final sameCache = ChatController(store);
        await sameCache.load();
        expect(sameCache.replyModel(sameCache.sessions.single), oldModel);
        sameCache.dispose();
        SharedPreferences.resetStatic();
        final cold = ChatController(SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: store.secrets));
        await cold.load();
        expect(cold.replyModel(cold.sessions.single), oldModel);
        cold.dispose();
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Chat settings'));
        await t.pumpAndSettle();
        expect(
            t
                .widget<TextField>(find.byKey(const Key('chat-reply-model')))
                .controller!
                .text,
            oldModel);
        await t.enterText(
            find.byKey(const Key('chat-reply-model')), 'explicit-retry');
        await t.ensureVisible(find.text('Save'));
        await t.tap(find.text('Save'));
        await t.pumpAndSettle();
        expect(c.replyModel(c.current!), 'explicit-retry');
        await t.pumpWidget(const SizedBox());
        c.dispose();
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }
  }

  testWidgets(
      'in-flight and accepted queue retain original model and instructions',
      (t) async {
    final arrived = Completer<void>();
    final response = Completer<http.Response>();
    final requests = <http.Request>[];
    final c = ChatController(await makeStore(),
        coreFactory: () => SaathiCore(client: MockClient((request) {
              requests.add(request);
              arrived.complete();
              return response.future;
            })));
    await setupChat(c);
    await c.saveChatSettings(c.current!,
        originalConnection: c.connections.single,
        selection: c.selectionGeneration,
        model: 'captured-model',
        instructions: 'Captured instructions',
        personaId: null);
    await showPanel(t, c);
    await t.enterText(
        find.byKey(const Key('chat-reply-model')), 'uncommitted-model');
    await t.enterText(find.byKey(const Key('composer')), 'Accepted input');
    await t.pump();
    await t.tap(find.byTooltip('Send'));
    for (var i = 0; i < 30 && !arrived.isCompleted; i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(arrived.isCompleted, isTrue,
        reason: 'busy=${c.busy}, error=${c.error}, queue=${c.queueStatus}');
    await t.enterText(find.byKey(const Key('composer')), 'Queued input');
    await t.pump();
    await t.tap(find.byTooltip('Send'));
    c.pauseQueue('Deliberate hold');
    await t.pump();
    expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull);
    await expectLater(
        c.saveChatSettings(c.current!,
            originalConnection: c.connections.single,
            selection: c.selectionGeneration,
            model: 'forbidden',
            instructions: 'forbidden',
            personaId: null),
        throwsStateError);
    expect(c.outbox.single.model, 'captured-model');
    expect(c.outbox.single.captured.instructions, 'Captured instructions');
    final body = jsonDecode(requests.single.body) as Map;
    expect(body['model'], 'captured-model');
    expect(
        (body['messages'] as List).first['content'], 'Captured instructions');
    response.complete(
        http.Response('{"choices":[{"message":{"content":"Answer"}}]}', 200));
    for (var i = 0; i < 30 && c.busy; i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(c.busy, isFalse);
    expect(c.current!.messages.last.content, 'Answer');
    await t.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(c.outbox.single.model, 'captured-model');
    await t.pumpWidget(const SizedBox());
    c.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  test('uncertain operation restores the exact override and prohibits edits',
      () async {
    final store = await makeStore();
    final c = ChatController(store,
        coreFactory: () => SaathiCore(
            client: MockClient((_) async => throw StateError('Lost result'))));
    await setupChat(c);
    await c.saveChatSettings(c.current!,
        originalConnection: c.connections.single,
        selection: c.selectionGeneration,
        model: 'captured-model',
        instructions: 'Captured instructions',
        personaId: null);
    expect(await c.send('Uncertain'), isFalse);
    final raw = store.preferences.getString(ChatController.preparedInputsKey);
    c.dispose();
    final restored = ChatController(store);
    await restored.load();
    restored.select(restored.sessions.single);
    expect(restored.uncertainInput!.model, 'captured-model');
    expect(restored.uncertainInput!.captured.instructions,
        'Captured instructions');
    await expectLater(
        restored.saveChatSettings(restored.current!,
            originalConnection: restored.connections.single,
            selection: restored.selectionGeneration,
            model: 'forbidden',
            instructions: 'forbidden',
            personaId: null),
        throwsStateError);
    expect(store.preferences.getString(ChatController.preparedInputsKey), raw);
    restored.dispose();
  });
}
