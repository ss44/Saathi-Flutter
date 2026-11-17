import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/chat_organization/organization_widgets.dart';

class ControlledOrganizationStorage extends OrganizationStorage {
  ControlledOrganizationStorage(super.preferences);
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<void> write(String value) async {
    await gate?.future;
    if (fail) throw StateError('controlled metadata failure');
    await super.write(value);
  }
}

class DelayedSecrets extends MemorySecrets {
  Completer<void>? gate;
  @override
  Future<String?> read(String id) async {
    await gate?.future;
    return super.read(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'inactive native chat keeps each authoritative work state independent of selected busy',
      () async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await c.load();
    final original =
        ChatSession(id: 'original', connectionId: 'native', model: 'model');
    final selected =
        ChatSession(id: 'selected', connectionId: 'direct', model: 'model');
    c.sessions.addAll([original, selected]);
    c.select(selected);
    for (final entry in {
      'queued': ConversationWorkState.queued,
      'running': ConversationWorkState.working,
      'waiting_for_approval': ConversationWorkState.awaitingInput,
      'unknown': ConversationWorkState.unknown,
      'new_status': ConversationWorkState.unknown,
      'failed': ConversationWorkState.failed,
      'cancelled': ConversationWorkState.cancelled,
      'interrupted': ConversationWorkState.cancelled,
      'completed': ConversationWorkState.idle,
    }.entries) {
      c.runs[original.id] = RunOperation({
        'key': 'operation',
        'local': original.id,
        'snapshot': {'status': entry.key, 'output': 'answer'},
        'committed': entry.key == 'completed'
      });
      expect(c.workState(original), entry.value, reason: entry.key);
      expect(c.workState(selected), ConversationWorkState.idle);
      expect(c.organization.entry(c.identityOf(original)).completions, isEmpty);
    }
    c.dispose();
  });
  test(
      'abandoning a recovered uncertain Direct input is durable and never resends it',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecrets();
    var requests = 0;
    SaathiCore core() => SaathiCore(client: MockClient((_) async {
          requests++;
          throw const SocketException('lost response');
        }));
    final c = ChatController(SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: core);
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', 'role');
    expect(await c.send('uncertain input'), isFalse);
    expect(c.uncertainInput, isNotNull);
    c.dispose();
    final restored = ChatController(
        SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: core);
    await restored.load();
    expect(restored.uncertainInput, isNotNull);
    await Future<void>.sync(
        () => restored.abandonHeldOutbox(restored.current!));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    restored.dispose();
    final again = ChatController(
        SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: core);
    await again.load();
    expect(again.uncertainInput, isNull);
    expect(again.outbox, isEmpty);
    expect(requests, 1);
    again.dispose();
  });

  test(
      'metadata completion failure retains answer and storage-only retry cannot duplicate inference',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = ControlledOrganizationStorage(prefs);
    var requests = 0;
    final c = ChatController(
        SaathiStore(preferences: prefs, secrets: MemorySecrets()),
        organizationStorage: storage,
        coreFactory: () => SaathiCore(client: MockClient((_) async {
              requests++;
              return http.Response(
                  '{"choices":[{"message":{"content":"retained answer"}}]}',
                  200);
            })));
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', 'role');
    final session = c.current!;
    final identity = c.identityOf(session);
    storage.fail = true;
    expect(await c.send('hello'), isTrue);
    expect(session.messages.last.content, 'retained answer');
    final id = session.messages.last.id!;
    expect(c.organization.entry(identity).completions, isEmpty);
    expect(c.organization.hasUnsavedChanges, isTrue);
    expect(c.submit('unsafe follower'), isFalse);
    await c.replyVisible(
        session, id); // unknown completion must not be acknowledged
    expect(c.organization.entry(identity).completions, isEmpty);
    storage.fail = false;
    await c.retryOrganizationSave();
    expect(requests, 1);
    expect(c.organization.entry(identity).completions, {id: false});
    await c.replyVisible(session, id);
    expect(c.organization.entry(identity).completions, {id: true});
    c.dispose();
  });

  test(
      'prepared Direct input cannot rebind to a replaced credential after restart',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = DelayedSecrets();
    var requests = 0;
    SaathiCore core() => SaathiCore(client: MockClient((_) async {
          requests++;
          return http.Response(
              '{"choices":[{"message":{"content":"unexpected"}}]}', 200);
        }));
    final c = ChatController(SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: core);
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', 'role');
    final original = c.current!;
    await c.addConnection({'id': 'b', 'name': 'B', 'type': 'openai'}, 'other');
    await c.newSession(c.connections.last, 'model', '');
    final independent = c.current!;
    c.select(original);
    secrets.gate = Completer<void>();
    final sending = c.send('held');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.pauseQueue('pause', allSources: true);
    secrets.gate!.complete();
    await sending;
    secrets.gate = null;
    await c.updateConnection('a', {...c.connections.first},
        apiKey: 'replacement');
    c.dispose();
    final restarted = ChatController(
        SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: core);
    await restarted.load();
    restarted
        .select(restarted.sessions.singleWhere((s) => s.id == original.id));
    expect(restarted.readOnly, isTrue);
    expect(restarted.uncertainInput?.text, 'held');
    expect(restarted.canResumeQueue, isFalse);
    expect(requests, 0);
    restarted
        .select(restarted.sessions.singleWhere((s) => s.id == independent.id));
    expect(restarted.readOnly, isFalse);
    expect(await restarted.send('independent input'), isTrue);
    expect(requests, 1);
    restarted.dispose();
  });

  test(
      'prepared Direct recovery uses captured role after restart and never automatically repeats uncertain input',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = DelayedSecrets();
    final bodies = <Map<String, dynamic>>[];
    SaathiCore core() => SaathiCore(client: MockClient((r) async {
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response(
              '{"choices":[{"message":{"content":"recovered answer"}}]}', 200);
        }));
    final c = ChatController(SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: core);
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', 'original captured role');
    secrets.gate = Completer<void>();
    final sending = c.send('prepared input');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.pauseQueue('Suspended before dispatch', allSources: true);
    c.dispose();
    secrets.gate!.complete();
    expect(await sending, isFalse);
    secrets.gate = null;
    expect(bodies, isEmpty);
    final recovered = ChatController(
        SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: core);
    await recovered.load();
    expect(recovered.outbox.single.captured.instructions,
        'original captured role');
    expect(bodies, isEmpty);
    await recovered.organization.savePersona(
        const SharedPersona(
            id: 'new', name: 'New', instructions: 'new mutable role'),
        canEdit: (_) => null);
    await recovered.organization.edit(recovered.identityOf(recovered.current!),
        displayName: '',
        personaId: 'new',
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null);
    recovered.resumeQueue();
    while (recovered.busy || bodies.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect((bodies.single['messages'] as List).first,
        {'role': 'system', 'content': 'original captured role'});
    recovered.dispose();
  });

  test(
      'completion arriving during archive metadata write is serialized without loss',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = ControlledOrganizationStorage(prefs);
    final response = Completer<http.Response>();
    final c = ChatController(
        SaathiStore(preferences: prefs, secrets: MemorySecrets()),
        organizationStorage: storage,
        coreFactory: () =>
            SaathiCore(client: MockClient((_) => response.future)));
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', '');
    final session = c.current!;
    final identity = c.identityOf(session);
    final sending = c.send('hello');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    storage.gate = Completer<void>();
    final archiving = c.organization.setArchived(identity, true);
    response.complete(http.Response(
        '{"choices":[{"message":{"content":"overlapping answer"}}]}', 200));
    await sending;
    expect(session.messages.last.content, 'overlapping answer');
    expect(c.organization.entry(identity).archived, isFalse);
    storage.gate!.complete();
    await archiving;
    storage.gate = null;
    while (!c.organization.entry(identity).unread) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(c.organization.entry(identity).archived, isTrue);
    expect(c.organization.entry(identity).unreadCompletionIds,
        [session.messages.last.id]);
    c.dispose();
  });

  test(
      'actual controller captures shared role before credentials, journals it, and durably records usage/unread',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = DelayedSecrets();
    final bodies = <Map<String, dynamic>>[];
    final answer = Completer<void>();
    final client = MockClient((r) async {
      bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
      await answer.future;
      return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'authoritative answer'}
              }
            ],
            'usage': {'prompt_tokens': 7, 'completion_tokens': 2},
            'runtime': {'secret': 'DO NOT SAVE'}
          }),
          200);
    });
    final c = ChatController(SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: () => SaathiCore(client: client));
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', 'fallback');
    final original = c.current!;
    final identity = c.identityOf(original);
    await c.organization.savePersona(
        const SharedPersona(
            id: 'role', name: 'Tutor', instructions: 'captured role'),
        canEdit: (_) => null);
    await c.organization.edit(identity,
        displayName: 'Renamed',
        personaId: 'role',
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null);
    secrets.gate = Completer<void>();
    expect(c.submit('hello'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.pendingPersonaReason(identity), isNotNull);
    expect(c.workState(original), ConversationWorkState.working);
    final journal = prefs.getString('saathi.prepared-inputs.v1')!;
    expect(journal, contains('captured role'));
    expect(journal, isNot(contains('fixture')));
    await expectLater(
        c.organization.savePersona(
            const SharedPersona(
                id: 'role', name: 'Tutor', instructions: 'changed'),
            canEdit: c.pendingPersonaReason),
        throwsStateError);
    secrets.gate!.complete();
    while (bodies.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final other = ChatSession(id: 'other', connectionId: 'a', model: 'model');
    c.sessions.add(other);
    c.select(other);
    expect(c.workState(original), ConversationWorkState.working);
    expect(c.workState(other), ConversationWorkState.idle);
    answer.complete();
    while (c.busy || !c.organization.entry(identity).unread) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect((bodies.single['messages'] as List).first,
        {'role': 'system', 'content': 'captured role'});
    final reply = original.messages.last;
    expect(reply.id, isNotNull);
    expect(reply.metadata['promptTokens'], 7);
    expect(prefs.getString('saathi.chats.v1'), isNot(contains('DO NOT SAVE')));
    c.dispose();
    final reload = ChatController(
        SaathiStore(preferences: prefs, secrets: secrets),
        coreFactory: () => SaathiCore(client: client));
    await reload.load();
    expect(reload.organization.entry(identity).unreadCompletionIds, [reply.id]);
    expect(reload.sessions.first.messages.last.metadata['completionTokens'], 2);
    expect(reload.displayTitle(reload.sessions.first), 'Renamed');
    reload.dispose();
    client.close();
  });
}
