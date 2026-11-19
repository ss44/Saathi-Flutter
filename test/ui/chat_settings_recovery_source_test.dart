import 'dart:async';

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
import 'package:saathi/ui/connections.dart';

import 'chat_settings_safety_test.dart' show setupChat, showPanel;

// Promotes the independent review73_recovery_source probe. Its raw reproduction
// and RED logs remain outside the source tree. Here protection is mandatory, not
// conditional on whether the destructive controls happen to be enabled.
void main() {
  for (final deleteConversation in [false, true]) {
    for (final throwsWrite in [false, true]) {
      testWidgets(
          'accepted settings retain source through Cancel and selection: delete=$deleteConversation throw=$throwsWrite',
          (t) async {
        const channel = MethodChannel('plugins.flutter.io/shared_preferences');
        final disk = <String, Object>{};
        final mutations = <MethodCall>[];
        final primaryGate = Completer<void>();
        var failSettings = false;
        var failedWrites = 0;
        var requests = 0;
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance =
            MethodChannelSharedPreferencesStore();
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
            (call) async {
          final args = call.arguments as Map?;
          if (call.method == 'getAll') return Map<String, Object>.from(disk);
          mutations.add(call);
          final fails = args?['key'] == 'flutter.${OrganizationStorage.key}' &&
              failSettings;
          if (fails) {
            failedWrites++;
            if (failedWrites == 1) {
              // Primary mutates durable storage; compensation does not. This
              // deliberately leaves the uncertain candidate on disk.
              disk[args!['key'] as String] = args['value'] as Object;
              await primaryGate.future;
            }
            if (throwsWrite) throw PlatformException(code: 'controlled-write');
            return false;
          }
          if (call.method.startsWith('set')) {
            disk[args!['key'] as String] = args['value'] as Object;
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
        final c = ChatController(store,
            coreFactory: () => SaathiCore(client: MockClient((_) async {
                  requests++;
                  return http.Response('Unexpected request', 500);
                })));
        await setupChat(c);
        final original = c.current!;
        final source = c.connections.single;
        await c.newSession(source, 'other-model', 'Other instructions');
        final other = c.current!;
        other.messages
            .add(ChatMessage(role: 'user', content: 'Other conversation'));
        await c.persist();
        c.select(original);
        final originalSecret = await store.readConnectionSecret('a');
        addTearDown(() async {
          if (!primaryGate.isCompleted) primaryGate.complete();
          await t.pumpWidget(const SizedBox());
          c.dispose();
        });
        await showPanel(t, c);
        await t.enterText(
            find.byKey(const Key('chat-reply-model')), 'candidate');
        await t.enterText(find.byKey(const Key('chat-instructions')),
            'Accepted instructions');
        failSettings = true;
        await t.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
        await t.tap(find.widgetWithText(FilledButton, 'Save'));
        await t.pump();
        expect(c.organization.saving, isTrue);

        Future<void> assertProtectedApis() async {
          final before = mutations.length;
          expect(c.canChangeConnections, isFalse);
          await expectLater(
              c.updateConnection(
                  'a', {...source, 'url': 'https://foreign.invalid'},
                  apiKey: 'replacement-fixture'),
              throwsStateError);
          await expectLater(c.deleteConnection('a'), throwsStateError);
          await expectLater(c.addConnection({...source, 'id': 'b'}, 'fixture'),
              throwsStateError);
          await expectLater(c.clear(), throwsStateError);
          expect(mutations.length, before,
              reason: 'Rejected transitions must not reach storage');
          expect(c.connections.single, same(source));
          expect(c.sessions, contains(original));
          expect(await store.readConnectionSecret('a'), originalSecret);
          expect(requests, 0);
        }

        await assertProtectedApis();
        primaryGate.complete();
        await t.pumpAndSettle();
        expect(failedWrites, 2);
        expect(find.textContaining('Storage recovery could not be confirmed'),
            findsOneWidget);
        expect(c.organization.hasUnsavedChanges, isTrue);
        expect(c.replyModel(original), 'original');
        final acceptedRaw = disk['flutter.${OrganizationStorage.key}'];
        expect(acceptedRaw, contains('candidate'));
        expect(acceptedRaw, contains('Accepted instructions'));
        expect(store.preferences.getString(OrganizationStorage.key), isNull);
        await t.ensureVisible(find.widgetWithText(TextButton, 'Cancel'));
        await t.tap(find.widgetWithText(TextButton, 'Cancel'));
        await t.pumpAndSettle();
        expect(c.organization.hasUnsavedChanges, isTrue);
        failSettings = false;
        await assertProtectedApis();

        final delete = find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == 'Delete conversation');
        expect(t.widget<IconButton>(delete).onPressed, isNull);
        await t.tap(delete);
        await t.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        await t.tap(find.descendant(
            of: find.byType(NavigationRail), matching: find.text('Settings')));
        await t.pumpAndSettle();
        final actions = find.byWidgetPredicate((w) =>
            w is PopupMenuButton<String> && w.tooltip == 'Connection actions');
        expect(t.widget<PopupMenuButton<String>>(actions).enabled, isFalse);
        await t.tap(actions);
        await t.pumpAndSettle();
        expect(find.byType(AddConnectionPage), findsNothing);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
        // The swipe action rail must not provide a second, unguarded Edit/Delete.
        await t.drag(
            find.widgetWithText(ListTile, 'Original'), const Offset(-220, 0));
        await t.pumpAndSettle();
        for (final action in ['Edit', 'Delete']) {
          expect(
              t
                  .widget<IconButton>(find.byWidgetPredicate(
                      (w) => w is IconButton && w.tooltip == action))
                  .onPressed,
              isNull);
        }
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();

        // Recover while another chat is selected, using the actual sidebar and
        // storage-only retry control. Never substitute that chat's settings.
        await t.tap(find.widgetWithText(ListTile, 'Other conversation'));
        await t.pumpAndSettle();
        expect(c.current, same(other));
        await assertProtectedApis();
        expect(c.organizationBlocked, isTrue);
        final retry = find.text('Try saving details again');
        expect(retry, findsOneWidget);
        await t.ensureVisible(retry);
        await t.tap(retry);
        await t.pumpAndSettle();
        expect(c.organization.hasUnsavedChanges, isFalse);
        expect(c.organizationBlocked, isFalse);
        expect(c.replyModel(original), 'candidate');
        final accepted = c.organization.entry(c.identityOf(original));
        expect(accepted.instructions, 'Accepted instructions');
        expect(accepted.personaId, isNull);
        expect(c.replyModel(other), 'other-model');
        expect(c.organization.entry(c.identityOf(other)).instructions, isNull);
        expect(c.current, same(other));
        expect(c.connections.single, same(source));
        expect(original.messages, isEmpty);
        expect(other.messages, hasLength(1));
        expect(requests, 0);
        expect(disk['flutter.${OrganizationStorage.key}'], acceptedRaw);
        expect(
            store.preferences.getString(OrganizationStorage.key), acceptedRaw);
        SharedPreferences.resetStatic();
        final cold = ChatController(SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: store.secrets));
        await cold.load();
        expect(
            cold.replyModel(
                cold.sessions.singleWhere((s) => s.id == original.id)),
            'candidate');
        expect(cold.organization.entry(c.identityOf(original)).instructions,
            'Accepted instructions');
        cold.dispose();

        await t.tap(find.widgetWithText(ListTile, 'New conversation'));
        await t.pumpAndSettle();
        expect(c.current, same(original));
        // Protection is temporary: exercise the real destructive paths after
        // recovery, including key replacement and original-source revocation.
        if (deleteConversation) {
          expect(t.widget<IconButton>(delete).onPressed, isNotNull);
          await t.tap(delete);
          await t.pumpAndSettle();
          await t.tap(find.descendant(
              of: find.byType(AlertDialog), matching: find.text('Delete')));
          await t.pumpAndSettle();
          expect(c.sessions, isNot(contains(original)));
          expect(c.sessions, contains(other));
        } else {
          final selection = c.selectionGeneration;
          await t.tap(find.descendant(
              of: find.byType(NavigationRail),
              matching: find.text('Settings')));
          await t.pumpAndSettle();
          expect(t.widget<PopupMenuButton<String>>(actions).enabled, isTrue);
          await t.tap(actions);
          await t.pumpAndSettle();
          await t.tap(find.text('Edit').last);
          await t.pumpAndSettle();
          expect(find.byType(AddConnectionPage), findsOneWidget);
          await t.enterText(
              find.byKey(const Key('connection-key')), 'replacement-fixture');
          await t.ensureVisible(find.text('Save connection'));
          await t.tap(find.text('Save connection'));
          await t.pumpAndSettle();
          expect(find.byType(AddConnectionPage), findsNothing);
          expect(c.isCurrentConnection(source), isFalse);
          expect(await store.readConnectionSecret('a'), 'replacement-fixture');
          await expectLater(
              c.saveChatSettings(original,
                  originalConnection: source,
                  selection: selection,
                  model: 'stale',
                  instructions: 'stale',
                  personaId: null),
              throwsStateError);
          expect(c.replyModel(original), 'candidate');
          await t.binding.handlePopRoute();
          await t.pumpAndSettle();
        }
        expect(c.organization.hasUnsavedChanges, isFalse);
        expect(requests, 0);
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }
  }
}
