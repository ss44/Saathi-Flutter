import 'dart:async';
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

import 'optimizer_settings_review_regression_test.dart' as fixture;

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fixture.channel, null);
    SharedPreferences.setMockInitialValues({});
  });

  for (final selection in ['global', 'chat', 'inherit']) {
    for (final action in [
      'cancel',
      'back',
      'escape',
      'covered',
      'new',
      'none'
    ]) {
      for (final success in [true, false]) {
        testWidgets('$selection pending save: $action success=$success',
            (t) async {
          final disk = fixture.Disk();
          final preferences = await disk.open();
          final requests = <http.Request>[];
          final client = MockClient((request) async {
            requests.add(request);
            return http.Response(
                jsonEncode({
                  'data': [
                    {'id': 'candidate'}
                  ]
                }),
                200);
          });
          final c = ChatController(
              SaathiStore(preferences: preferences, secrets: MemorySecrets()),
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
          await c.saveOptimizerSelection(fixture.old);
          await c.saveOptimizerSelection(fixture.old, chat: chat);
          final before = preferences.get(fixture.key);
          t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
          await t.pumpAndSettle();
          await t.enterText(find.byType(TextField), 'Retained private draft');
          await t.tap(find.byTooltip('Settings'));
          await t.pumpAndSettle();
          final label = selection == 'global'
              ? 'Global prompt optimizer'
              : 'Chat prompt optimizer';
          await t.scrollUntilVisible(find.text(label), 200);
          await t.tap(find.text(label));
          await t.pumpAndSettle();
          final dialog = t.state(find.byType(OptimizerSettingsDialog));
          final route = ModalRoute.of(dialog.context)!;
          final navigator = route.navigator!;
          if (selection != 'inherit') {
            await t.tap(find.descendant(
                of: find.byType(AlertDialog), matching: find.text('Source')));
            for (var i = 0; i < 8; i++) {
              await t.pump();
              await t.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)));
            }
            await t.pumpAndSettle();
          }
          final gate = Completer<bool>();
          final firstWrite = disk.writes + 1;
          disk.onWrite =
              (n) => n == firstWrite ? gate.future : Future.value(true);
          await t.tap(find.text(
              selection == 'inherit' ? 'Inherit global setting' : 'candidate'));
          await t.pump();
          expect(c.optimizerSettingsSaving, isTrue);
          expect(c.globalOptimizerSelection, fixture.old);
          expect(c.optimizerOverride(chat), fixture.old);
          if (action == 'cancel' || action == 'new') {
            await t.tap(find.text('Cancel'));
          } else if (action == 'back') {
            await t.binding.handlePopRoute();
          } else if (action == 'escape') {
            await t.sendKeyEvent(LogicalKeyboardKey.escape);
          } else if (action == 'covered') {
            unawaited(navigator.push(MaterialPageRoute<void>(
                builder: (_) =>
                    const Scaffold(body: Text('Newer details route')))));
          }
          await t.pump(const Duration(milliseconds: 10));
          if (action == 'new') {
            unawaited(navigator.push(DialogRoute<void>(
                context: navigator.context,
                builder: (_) => OptimizerSettingsDialog(
                    key: const ValueKey('new-dialog'),
                    controller: c,
                    chat: chat))));
            await t.pump(const Duration(milliseconds: 10));
          }
          expect(dialog.mounted, isTrue,
              reason:
                  'Exercise completion before the reverse transition disposes its owner');
          expect(route.isCurrent, action == 'none');
          gate.complete(success);
          await t.pumpAndSettle();
          expect(c.optimizerSettingsSaving, isFalse);
          if (success) {
            expect(c.globalOptimizerSelection,
                selection == 'global' ? fixture.candidate : fixture.old);
            expect(
                c.optimizerOverride(chat),
                selection == 'inherit'
                    ? null
                    : selection == 'chat'
                        ? fixture.candidate
                        : fixture.old);
          } else {
            expect(c.globalOptimizerSelection, fixture.old);
            expect(c.optimizerOverride(chat), fixture.old);
            expect(preferences.get(fixture.key), before);
          }
          expect(disk.values['flutter.${fixture.key}'],
              preferences.get(fixture.key));
          final cold = ChatController(SaathiStore(
              preferences: await disk.open(), secrets: MemorySecrets()));
          expect(cold.globalOptimizerSelection, c.globalOptimizerSelection);
          expect(cold.optimizerOverride(chat), c.optimizerOverride(chat));
          cold.dispose();
          if (action == 'covered') {
            expect(find.text('Newer details route'), findsOneWidget);
            navigator.pop();
            await t.pumpAndSettle();
          }
          if (action == 'new') {
            expect(find.byKey(const ValueKey('new-dialog')), findsOneWidget);
            expect(
                find.text('Could not save. Please try again.'), findsNothing);
          } else if (action == 'covered' || (action == 'none' && !success)) {
            expect(find.byType(OptimizerSettingsDialog), findsOneWidget);
            expect(find.text('Could not save. Please try again.'),
                success ? findsNothing : findsOneWidget);
            if (selection == 'inherit') {
              expect(
                  t
                      .widget<TextButton>(find.widgetWithText(
                          TextButton, 'Inherit global setting'))
                      .onPressed,
                  isNotNull);
            }
          } else {
            expect(find.byType(OptimizerSettingsDialog), findsNothing);
          }
          if (find.byType(OptimizerSettingsDialog).evaluate().isNotEmpty) {
            await t.tap(find.text('Cancel'));
            await t.pumpAndSettle();
          }
          expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
          expect(chat.model, 'response');
          expect(chat.systemPrompt, 'instructions');
          expect(requests.map((r) => r.method),
              selection == 'inherit' ? isEmpty : ['GET']);
          await t.pageBack();
          await t.pumpAndSettle();
          expect(find.widgetWithText(TextField, 'Retained private draft'),
              findsOneWidget);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox.shrink());
          c.dispose();
          client.close();
        });
      }
    }
  }
}
