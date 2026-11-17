import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'hermes_gateway_test.dart' show Fixture, snapshot;

class DelayedSecrets extends MemorySecrets {
  DelayedSecrets(this.gate);
  final Completer<void> gate;
  @override
  Future<void> write(String id, String value) async {
    await gate.future;
    await super.write(id, value);
  }
}

void main() {
  test('canonical preview is bounded and terminal receipt still reconciles',
      () async {
    final fixture = Fixture();
    await fixture.start();
    var terminal = false;
    fixture.respond = (r) => r['method'] == 'session.resume'
        ? snapshot()
        : {
            'admission_id': 'run',
            'ref': {'session_id': 'chat', 'profile_id': 'profile'},
            'authority_epoch': 3,
            'execution_generation': 4,
            'status': terminal ? 'terminal' : 'started',
            if (terminal) 'outcome': 'completed',
          };
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        MemorySecrets(),
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    await chat.send('work');
    for (var i = 1; i <= 6; i++) {
      fixture.event('message.delta', {'text': 'x' * 65536}, sequence: i);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(chat.streamText!.length, lessThanOrEqualTo(256 * 1024));
    expect(chat.problem, contains('preview'));
    await chat.control('steer', text: 'finish carefully');
    expect(chat.problem, contains('preview'),
        reason: 'Control feedback must not conceal omitted live text');
    expect(chat.pending, isTrue);
    terminal = true;
    expect(await chat.refresh(), isTrue);
    await chat.markSnapshotSaved();
    expect(chat.pending, isFalse);
    expect(chat.streamText, isNull);
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });
  test(
      'native approval requires a reviewable command, not descriptive fallback',
      () async {
    final fixture = Fixture();
    await fixture.start();
    Object? command;
    fixture.respond = (r) => r['method'] == 'session.resume'
        ? {
            ...snapshot(),
            'prompts': [
              {
                'kind': 'approval',
                'prompt_id': 'p',
                'execution_generation': 4,
                'description': 'A harmless description',
                if (command != null) 'command': command,
                'choices': ['once', 'deny', 'always'],
              }
            ],
          }
        : {'status': 'resolved', 'prompt_id': 'p'};
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    await client.connect();
    for (final value in [
      null,
      '',
      '  ',
      '{"tool":"raw"}',
      '\u202e\u200b',
      'sk-abcdefghijk'
    ]) {
      command = value;
      final prompt = (await client.attach('chat')).requests.single;
      expect(await client.decide(prompt, 'once'), isFalse, reason: '$value');
      expect(await client.decide(prompt, 'always'), isFalse, reason: '$value');
      expect(await client.decide(prompt, 'deny'), isTrue);
    }
    command = 'echo inspectable';
    final prompt = (await client.attach('chat')).requests.single;
    expect(await client.decide(prompt, 'once'), isTrue);
    expect(await client.decide(prompt, 'always'), isTrue,
        reason: 'The native advertised choice vocabulary is preserved');
  });
  test(
      'selection revokes writes permanently but original-source observation can reconcile',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.respond = (_) => snapshot();
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        MemorySecrets(),
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    chat.revokeInput();
    expect(chat.connected, isFalse);
    expect(await chat.refresh(), isTrue);
    await chat.markSnapshotSaved();
    expect(chat.connected, isFalse);
    await expectLater(chat.send('never revive'), throwsStateError);
    expect(
        fixture.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });
  test(
      'stored submission metadata proves landed but never invents a terminal receipt',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.dropSubmitAck = true;
    String? inputId;
    fixture.respond = (_) => {
          ...snapshot(),
          'messages': [
            {
              'role': 'user',
              'content': 'same words',
              'display_metadata': {'submission_id': inputId}
            },
            {'role': 'assistant', 'content': 'not proof of ownership'},
          ]
        };
    final chat = CanonicalChat(
        HermesGatewayClient(
            requestTimeout: const Duration(milliseconds: 100),
            grantProvider: () async => fixture.grant()),
        MemorySecrets(),
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    await expectLater(
        chat.send('same words'), throwsA(isA<GatewayException>()));
    inputId = fixture.requests.last['params']['input_id'] as String;
    expect(await chat.refresh(), isFalse);
    expect(chat.problem, contains('landed'));
    expect(chat.pending, isTrue);
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });
  test(
      'external resync locks dispatch before listener notification until durable save',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.respond = (_) => snapshot();
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        MemorySecrets(),
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    Future<void>? reentrant;
    void listener() {
      reentrant ??= expectLater(chat.send('must stay held'), throwsStateError);
    }

    chat.addListener(listener);
    expect(await chat.refresh(), isTrue);
    await reentrant;
    chat.removeListener(listener);
    expect(chat.awaitingSnapshotSave, isTrue);
    await expectLater(chat.send('still held'), throwsStateError);
    await chat.markSnapshotSaved();
    expect(chat.awaitingSnapshotSave, isFalse);
    expect(
        fixture.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });
  test(
      'prepared journal restores held text without dispatch and remains durable',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.respond = (_) => snapshot();
    final secrets = MemorySecrets();
    await secrets.write('gateway.journal.source.chat',
        '{"inputId":"held-id","text":"Held original","sessionId":"chat","profileId":"profile","state":"prepared"}');
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        secrets,
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    expect(chat.pending, isFalse);
    expect(chat.heldInput, 'Held original');
    expect(chat.heldInputId, 'held-id');
    expect(await secrets.read('gateway.journal.source.chat'),
        contains('Held original'));
    expect(
        fixture.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
    expect(await chat.discardHeldInput('foreign-id'), isFalse);
    expect(chat.heldInput, 'Held original');
    expect(await chat.discardHeldInput('held-id'), isTrue);
    expect(chat.heldInput, isNull);
    expect(await secrets.read('gateway.journal.source.chat'), isNull);
  });
  test(
      'native decisions use advertised prompt choices and generation without inference',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.respond = (r) => r['method'] == 'session.resume'
        ? {
            ...snapshot(),
            'prompts': [
              {
                'kind': 'approval',
                'prompt_id': 'approve',
                'execution_generation': 4,
                'choices': ['once', 'deny'],
                'description': 'Review this action',
                'command': 'echo reviewable fixture'
              },
              {
                'kind': 'clarify',
                'prompt_id': 'clarify',
                'execution_generation': 4,
                'choices': ['A', 'B'],
                'question': 'Which one?'
              },
            ]
          }
        : {
            'status': 'resolved',
            'prompt_id': (r['params'] as Map)['prompt_id']
          };
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        MemorySecrets(),
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    final approval = chat.snapshot!.requests.first;
    expect(await chat.decide(approval, 'session'), isFalse,
        reason: 'not advertised');
    expect(await chat.decide(approval, 'once'), isTrue);
    final clarification = chat.snapshot!.requests.last;
    expect(await chat.decide(clarification, 'B'), isTrue);
    expect(
        fixture.requests
            .where((r) => r['method'] == 'approval.respond')
            .single['params'],
        {
          'session_id': 'chat',
          'execution_generation': 4,
          'prompt_id': 'approve',
          'choice': 'once'
        });
    expect(
        fixture.requests
            .where((r) => r['method'] == 'clarify.respond')
            .single['params']['answer'],
        'B');
    expect(
        fixture.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
    chat.suspend();
    expect(await chat.decide(approval, 'once'), isFalse);
  });
  test(
      'native control ACK does not complete work and rejects stale or refused guidance',
      () async {
    final fixture = Fixture();
    await fixture.start();
    var reject = false;
    fixture.respond = (r) => switch (r['method']) {
          'session.resume' => snapshot(),
          'prompt.submit' => {
              'admission_id': 'run',
              'ref': {'session_id': 'chat', 'profile_id': 'profile'},
              'authority_epoch': 3,
              'execution_generation': 4,
              'status': 'started',
            },
          _ => {
              'status': reject ? 'rejected' : 'queued',
              'execution_generation': 4,
              'authority_epoch': 3
            },
        };
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        MemorySecrets(),
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    await chat.send('work');
    expect(chat.canControl, isTrue);
    expect(await chat.control('steer', text: 'guide'), isTrue);
    expect(await chat.control('interrupt'), isTrue);
    expect(chat.pending, isTrue, reason: 'Stop ACK is not terminal');
    reject = true;
    expect(await chat.control('redirect', text: 'keep this draft'), isFalse);
    chat.suspend();
    expect(await chat.control('steer', text: 'stale'), isFalse);
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });
  test('lost ACK recovers exact pending input identity read-only after restart',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.dropSubmitAck = true;
    String? input;
    Map<String, dynamic> receipt() => {
          'admission_id': 'exact-run',
          'ref': {'session_id': 'chat', 'profile_id': 'profile'},
          'authority_epoch': 3,
          'execution_generation': 4,
          'status': 'terminal',
          'outcome': 'completed',
        };
    fixture.respond = (r) => r['method'] == 'prompt.receipt'
        ? receipt()
        : {
            ...snapshot(),
            'pending': [
              if (input != null)
                {...receipt(), 'input_id': input, 'text': 'not identity'}
            ],
          };
    final secrets = MemorySecrets();
    CanonicalChat owner() => CanonicalChat(
        HermesGatewayClient(
            requestTimeout: const Duration(milliseconds: 100),
            grantProvider: () async => fixture.grant()),
        secrets,
        source: 'source',
        isCurrent: () => true);
    final first = owner();
    await first.connect();
    await first.attach('chat');
    await expectLater(first.send('same text is not attribution'),
        throwsA(isA<GatewayException>()));
    input = fixture.requests.last['params']['input_id'] as String;
    await first.close();
    final recovered = owner();
    addTearDown(() async {
      await recovered.close();
      await fixture.close();
    });
    await recovered.connect();
    await recovered.attach('chat');
    expect(await recovered.refresh(), isTrue);
    expect(recovered.pending, isTrue,
        reason: 'durable snapshot save still required');
    await recovered.markSnapshotSaved();
    expect(recovered.pending, isFalse);
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
    expect(
        fixture.requests
            .where((r) => r['method'] == 'prompt.receipt')
            .single['params']['admission_id'],
        'exact-run');
  });
  test(
      'external-client completion resync replaces streamed text with authoritative history',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.respond = (_) => snapshot();
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        MemorySecrets(),
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    fixture.event('message.delta', {'text': 'External streamed text'},
        admission: 'other-client');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(chat.streamText, 'External streamed text');
    expect(await chat.refresh(), isTrue);
    expect(chat.streamText, isNull);
  });
  test(
      'lost ACK survives owner restart and reconnect without a second inference',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.dropSubmitAck = true;
    fixture.respond = (_) => snapshot();
    final secrets = MemorySecrets();
    CanonicalChat owner() => CanonicalChat(
        HermesGatewayClient(
            requestTimeout: const Duration(milliseconds: 500),
            grantProvider: () async => fixture.grant()),
        secrets,
        source: 'source',
        isCurrent: () => true);
    final first = owner();
    await first.connect();
    await first.attach('chat');
    await expectLater(
        first.send('Unknown input'), throwsA(isA<GatewayException>()));
    expect(first.pending, isTrue);
    await first.close();
    final recovered = owner();
    addTearDown(() async {
      await recovered.close();
      await fixture.close();
    });
    await recovered.connect();
    await recovered.attach('chat');
    expect(await recovered.refresh(), isFalse);
    expect(recovered.pending, isTrue);
    await expectLater(recovered.send('Unknown input'), throwsStateError);
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
    expect(await secrets.read('gateway.journal.source.chat'),
        contains('Unknown input'));
    await recovered.close();
    fixture.profileId = 'foreign-profile';
    final foreign = owner();
    addTearDown(foreign.close);
    await foreign.connect();
    await expectLater(foreign.attach('chat'), throwsA(isA<GatewayException>()));
  });
  test(
      'suspension permanently revokes a pending secure-store write before dispatch',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final gate = Completer<void>();
    final secrets = DelayedSecrets(gate);
    fixture.respond = (_) => snapshot();
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        secrets,
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    final sending = chat.send('held');
    await Future<void>.delayed(Duration.zero);
    chat.suspend();
    gate.complete();
    await expectLater(sending, throwsStateError);
    expect(
        fixture.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
    expect(chat.connected, isFalse);
    expect(chat.pending, isFalse,
        reason:
            'A proven pre-dispatch revocation must return to the held FIFO, not become unknown');
    expect(await secrets.read('gateway.journal.source.chat'), isNull);
  });
  test(
      'journals before submit and holds admission until authoritative snapshot is saved',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final secrets = MemorySecrets();
    fixture.respond = (request) => switch (request['method']) {
          'session.resume' => snapshot(),
          'prompt.submit' || 'prompt.receipt' => {
              'admission_id': 'run',
              'ref': {'session_id': 'chat', 'profile_id': 'profile'},
              'authority_epoch': 3,
              'execution_generation': 4,
              'status': 'started',
            },
          _ => {'sessions': []},
        };
    final chat = CanonicalChat(
        HermesGatewayClient(grantProvider: () async => fixture.grant()),
        secrets,
        source: 'source',
        isCurrent: () => true);
    addTearDown(() async {
      await chat.close();
      await fixture.close();
    });
    await chat.connect();
    await chat.attach('chat');
    await chat.send('New prompt');
    expect(chat.pending, isTrue);
    expect(await secrets.read('gateway.journal.source.chat'),
        contains('admissionId'));
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
    await expectLater(chat.send('duplicate'), throwsStateError);
    expect(chat.messages.first.text, 'Earlier input');
  });
}
