import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/chat_organization/organization_widgets.dart';

class ControlledStorage extends OrganizationStorage {
  ControlledStorage(super.preferences);
  bool fail = false;
  Completer<void>? delay;
  @override
  Future<void> write(String value) async {
    await delay?.future;
    if (fail) throw StateError('Controlled storage failure');
    await super.write(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = ConversationIdentity('original', 'chat');
  test('normal completion capacity has a typed original-conversation failure',
      () async {
    SharedPreferences.setMockInitialValues({
      OrganizationStorage.key: jsonEncode({
        'schema': 1,
        'chats': {
          id.storageKey: {
            'displayName': '',
            'archived': false,
            'completions': {for (var i = 0; i < 512; i++) '$i': true},
          }
        },
      }),
    });
    final organization = ChatOrganization(
        OrganizationStorage(await SharedPreferences.getInstance()));
    await organization.load();
    await expectLater(
        organization.recordCompletion(id, 'next'),
        throwsA(
            predicate((dynamic e) => e is! StateError && e.identity == id)));
    expect(organization.entry(id).completions.length, 512);
    expect(organization.hasUnsavedChanges, isFalse);
    await organization.recordCompletion(
        const ConversationIdentity('original', 'other'), 'healthy');
  });
  testWidgets('an editor cannot adopt or cancel another failed reply write',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = ControlledStorage(await SharedPreferences.getInstance());
    final organization = ChatOrganization(storage);
    await organization.load();
    storage.fail = true;
    await expectLater(
        organization.recordCompletion(id, 'unseen'), throwsStateError);
    final key = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            key: key,
            body: TextButton(
                onPressed: () => showConversationEdit(
                    context: key.currentContext!,
                    organization: organization,
                    identity: id,
                    fallbackInstructions: '',
                    policy: (_) => PersonaEditPolicy.localInstructions,
                    pendingReason: (_) => null),
                child: const Text('Edit')))));
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('conversation-name')), 'Not committed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Try saving again'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(organization.hasUnsavedChanges, isTrue);
    expect(organization.entry(id).displayName, '');
    expect(tester.takeException(), isNull);
    storage.fail = false;
    await organization.retrySave();
    expect(organization.entry(id).unreadCompletionIds, ['unseen']);
  });
  test(
      'a failed persona selection rechecks dynamic restriction before any retry',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = ControlledStorage(await SharedPreferences.getInstance());
    final organization = ChatOrganization(storage);
    await organization.load();
    await organization.savePersona(
        const SharedPersona(id: 'p', name: 'Role', instructions: 'Future'),
        canEdit: (_) => null);
    String? restriction;
    storage.fail = true;
    await expectLater(
        organization.edit(id,
            displayName: '',
            personaId: 'p',
            policy: PersonaEditPolicy.localInstructions,
            pendingReason: null,
            revalidatePersonaChange: () => restriction),
        throwsStateError);
    restriction = 'Working';
    storage.fail = false;
    await expectLater(organization.retrySave(), throwsStateError);
    expect(organization.entry(id).personaId, isNull);
    restriction = null;
    await organization.retrySave();
    expect(organization.entry(id).personaId, 'p');
  });
  test('scoped reply IDs do not collide, save failure retains unread candidate',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = ControlledStorage(await SharedPreferences.getInstance());
    final organization = ChatOrganization(storage);
    await organization.load();
    const other = ConversationIdentity('different connection', 'chat');
    await organization.recordCompletion(id, 'reply');
    await organization.recordCompletion(other, 'reply');
    await organization.markReplyVisible(id, 'reply');
    expect(organization.entry(other).unread, isTrue);
    storage.fail = true;
    await expectLater(
        organization.markReplyVisible(other, 'reply'), throwsStateError);
    expect(organization.entry(other).unread, isTrue);
    expect(organization.hasUnsavedChanges, isTrue);
    expect(organization.discardPendingEdit, throwsStateError);
    await expectLater(organization.load(), throwsStateError);
    storage.fail = false;
    await organization.retrySave();
    expect(organization.entry(other).unread, isFalse);
    await organization.recordCompletion(other, 'reply');
    expect(organization.entry(other).unread, isFalse);
  });
  test(
      'bounded typed metadata refuses malformed or oversized records without replacing data',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final organization = ChatOrganization(OrganizationStorage(prefs));
    await organization.load();
    await organization.edit(id,
        displayName: 'Keep',
        personaId: null,
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null);
    final safe = organization.toJson();
    for (final invalid in [
      {'schema': 99, 'chats': {}},
      {
        'schema': 1,
        'chats': {'wrong key': {}}
      },
      {
        'schema': 1,
        'chats': {
          id.storageKey: {
            'displayName': false,
            'archived': false,
            'completions': {}
          }
        }
      },
      {
        'schema': 1,
        'chats': {
          id.storageKey: {
            'displayName': '',
            'archived': false,
            'completions': {'reply': 'true'}
          }
        }
      },
      {
        'schema': 1,
        'chats': {
          id.storageKey: {
            'displayName': '',
            'archived': false,
            'completions': {for (var n = 0; n < 513; n++) '$n': false}
          }
        }
      },
      {
        'schema': 1,
        'chats': {},
        'personas': [
          {'id': 'p', 'name': 'Persona', 'instructions': '', 'revision': 0}
        ]
      },
    ]) {
      await prefs.setString(OrganizationStorage.key, jsonEncode(invalid));
      await expectLater(organization.load(), throwsFormatException);
      expect(organization.toJson(), safe);
    }
    await prefs.setString(OrganizationStorage.key, 'x' * (2 * 1024 * 1024 + 1));
    await expectLater(organization.load(), throwsFormatException);
    await expectLater(
        organization.recordCompletion(id, 'x' * 257), throwsArgumentError);
    await expectLater(
        organization.edit(id,
            displayName: 'x' * 121,
            personaId: null,
            policy: PersonaEditPolicy.localInstructions,
            pendingReason: null),
        throwsArgumentError);
  });
  testWidgets(
      'failed Save retains draft for retry; Cancel never commits an unsaved rename',
      (tester) async {
    tester.view.physicalSize = const Size(360, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final storage = ControlledStorage(await SharedPreferences.getInstance());
    final organization = ChatOrganization(storage);
    await organization.load();
    final key = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(
            key: key,
            body: TextButton(
                onPressed: () => showConversationEdit(
                    context: key.currentContext!,
                    organization: organization,
                    identity: id,
                    fallbackInstructions: 'Original',
                    policy: (_) => PersonaEditPolicy.localInstructions,
                    pendingReason: (_) => null),
                child: const Text('Edit')))));
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('conversation-name')), 'Unsaved draft');
    storage.fail = true;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Try saving again'), findsOneWidget);
    expect(find.text('Unsaved draft'), findsOneWidget);
    expect(organization.entry(id).displayName, '');
    storage.fail = false;
    await tester.tap(find.text('Try saving again'));
    await tester.pumpAndSettle();
    expect(organization.entry(id).displayName, 'Unsaved draft');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('conversation-name')), 'Cancelled draft');
    storage.fail = true;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(organization.hasUnsavedChanges, isFalse);
    expect(organization.entry(id).displayName, 'Unsaved draft');
    expect(tester.takeException(), isNull);
  });
}
