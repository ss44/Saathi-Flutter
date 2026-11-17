import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FailingOrganizationStorage extends OrganizationStorage {
  FailingOrganizationStorage(super.preferences);
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
  const a = ConversationIdentity('connection', 'a');
  test(
      'rename and archive preserve identity; shared personas capture future context',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final organization = ChatOrganization(OrganizationStorage(prefs));
    await organization.load();
    await organization.savePersona(
        const SharedPersona(
            id: 'coach', name: 'Coach', instructions: 'Be concise.'),
        canEdit: (_) => null);
    await organization.edit(a,
        displayName: 'Planning',
        personaId: 'coach',
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null);
    const b = ConversationIdentity('connection', 'b');
    await organization.edit(b,
        displayName: '',
        personaId: 'coach',
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null);
    final captured = organization.captureInstructions(a, fallback: 'Default');
    expect(captured.instructions, 'Be concise.');
    expect(organization.affectedChats('coach').toSet(), {a, b});
    await organization.savePersona(
        const SharedPersona(
            id: 'coach',
            name: 'Coach',
            instructions: 'Use examples.',
            revision: 2),
        canEdit: (_) => null);
    expect(captured.instructions, 'Be concise.');
    expect(organization.captureInstructions(b, fallback: '').instructions,
        'Use examples.');
    await organization.setArchived(a, true);
    final restarted = ChatOrganization(OrganizationStorage(prefs));
    await restarted.load();
    expect(restarted.entry(a).archived, isTrue);
    expect(restarted.entry(a).title('First message'), 'Planning');
    expect(restarted.captureInstructions(a, fallback: '').instructions,
        'Use examples.');
    await restarted.setArchived(a, false);
    expect(restarted.entry(a).archived, isFalse);
    expect(
        () => restarted.edit(a,
            displayName: 'Planning',
            personaId: null,
            policy: PersonaEditPolicy.serverOwned,
            pendingReason: null),
        throwsStateError);
    expect(
        () => restarted.edit(a,
            displayName: 'Planning',
            personaId: null,
            policy: PersonaEditPolicy.localInstructions,
            pendingReason: 'Queued input'),
        throwsStateError);
    expect(
        () => restarted.savePersona(
            const SharedPersona(
                id: 'coach', name: 'Coach', instructions: 'Changed'),
            canEdit: (key) => key == b ? 'Working' : null),
        throwsStateError);
  });

  test('disposal during storage never publishes to dead controller', () async {
    SharedPreferences.setMockInitialValues({});
    final storage =
        FailingOrganizationStorage(await SharedPreferences.getInstance());
    final organization = ChatOrganization(storage);
    await organization.load();
    storage.delay = Completer<void>();
    final saving = organization.recordCompletion(a, 'answer');
    organization.dispose();
    storage.delay!.complete();
    await saving;
    await expectLater(
        organization.recordCompletion(a, 'after-disposal'), throwsStateError);
    expect(jsonDecode(storage.read()!)['chats'][a.storageKey]['completions'],
        {'answer': false});
  });
  test(
      'unregistered reply visibility cannot be acknowledged ahead of completion persistence',
      () async {
    SharedPreferences.setMockInitialValues({});
    final organization = ChatOrganization(
        OrganizationStorage(await SharedPreferences.getInstance()));
    await organization.load();
    await expectLater(
        organization.markReplyVisible(a, 'not-yet-recorded'), throwsStateError);
    expect(organization.entry(a).completions, isEmpty);
    await organization.recordCompletion(a, 'not-yet-recorded');
    expect(organization.entry(a).unread, isTrue);
    await organization.markReplyVisible(a, 'not-yet-recorded');
    expect(organization.entry(a).unread, isFalse);
  });
  test('retry revalidates all shared chats after pending work changes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage =
        FailingOrganizationStorage(await SharedPreferences.getInstance());
    final organization = ChatOrganization(storage);
    await organization.load();
    await organization.savePersona(
        const SharedPersona(id: 'shared', name: 'Role', instructions: 'Before'),
        canEdit: (_) => null);
    await organization.edit(a,
        displayName: '',
        personaId: 'shared',
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null);
    String? pending;
    storage.fail = true;
    await expectLater(
        organization.savePersona(
            const SharedPersona(
                id: 'shared', name: 'Role', instructions: 'After'),
            canEdit: (_) => pending),
        throwsStateError);
    pending = 'Queued input keeps captured instructions';
    storage.fail = false;
    await expectLater(organization.retrySave(), throwsStateError);
    expect(organization.captureInstructions(a, fallback: '').instructions,
        'Before');
    pending = null;
    await organization.retrySave();
    expect(organization.captureInstructions(a, fallback: '').instructions,
        'After');
  });
  test('completion identity and seen markers survive restart without replay',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final organization = ChatOrganization(OrganizationStorage(prefs));
    await organization.load();
    await organization.recordCompletion(a, 'reply-1');
    expect(organization.entry(a).unread, isTrue);
    // Selecting a conversation is deliberately not an organization operation.
    await organization.markReplyVisible(a, 'reply-1');
    final restarted = ChatOrganization(OrganizationStorage(prefs));
    await restarted.load();
    await restarted.recordCompletion(a, 'reply-1');
    expect(restarted.entry(a).unread, isFalse);
    await restarted.recordCompletion(a, 'reply-2');
    expect(restarted.entry(a).unreadCompletionIds, ['reply-2']);
    expect(jsonEncode(restarted.toJson()), isNot(contains('apiKey')));
  });
}
