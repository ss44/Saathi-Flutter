import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/openclaw/openclaw_domain.dart';

void main() {
  test('catalog uses genuine provider model tuples, not compatibility agents',
      () {
    final models = OpenClawModel.parseCatalog({
      'models': [
        {'id': 'same', 'provider': 'one', 'name': 'One'},
        {'id': 'same', 'provider': 'two', 'name': 'Two'},
      ]
    });
    expect(models.map((m) => m.reference), ['one/same', 'two/same']);
    expect(
        () => OpenClawModel.parseCatalog({
              'agents': [
                {'id': 'main'}
              ]
            }),
        throwsFormatException);
    expect(
        () => OpenClawModel.parseCatalog({
              'models': [
                {'id': 'no-provider'}
              ]
            }),
        throwsFormatException);
  });
  test('challenge proof is exact and can be revoked during signing', () async {
    final source = OpenClawSource('a', Uri.parse('wss://example.test/prefix'));
    final authority = OpenClawAuthority(source);
    const credentials = OpenClawCredentials(
        deviceId: 'device', publicKey: 'public', token: 'token');
    String? proof;
    final params = await authority.prepareConnect(
        challenge: {'nonce': 'nonce', 'ts': 12},
        loadCredentials: () async => credentials,
        sign: (payload) async {
          proof = payload;
          return 'sig';
        });
    expect(proof,
        'v3|device|webchat|webchat|operator|operator.read,operator.write|12|token|nonce|flutter|');
    expect((params['device'] as Map)['signedAt'], 12);
    expect(params['scopes'], ['operator.read', 'operator.write']);
    final signing = Completer<String>();
    final pending = authority.prepareConnect(
        challenge: {'nonce': 'new', 'ts': 13},
        loadCredentials: () async => credentials,
        sign: (_) => signing.future);
    await Future<void>.delayed(Duration.zero);
    final rejected = expectLater(pending, throwsStateError);
    authority.revoke();
    signing.complete('too-late');
    await rejected;
    for (final challenge in [
      {'nonce': 'x'},
      {'nonce': '', 'ts': 0},
      {'nonce': 'x', 'ts': -1},
      {'nonce': 'x', 'ts': 1.5}
    ]) {
      await expectLater(
          OpenClawAuthority(source).prepareConnect(
              challenge: challenge,
              loadCredentials: () async => credentials,
              sign: (_) async => 'unused'),
          throwsFormatException);
    }
    for (final url in [
      'ws://remote.test',
      'wss://user@remote.test',
      'wss://remote.test?token=x',
      'wss://remote.test#x',
      'https://remote.test'
    ]) {
      expect(() => OpenClawSource('a', Uri.parse(url)), throwsArgumentError);
    }
  });
  test('revoked source cannot finish a delayed credential read', () async {
    final source = OpenClawSource('original', Uri.parse('wss://example.test'));
    final authority = OpenClawAuthority(source);
    final credential = Completer<OpenClawCredentials>();
    var signatures = 0;
    final preparation = authority.prepareConnect(
      challenge: {'nonce': 'server-nonce', 'ts': 10},
      loadCredentials: () => credential.future,
      sign: (payload) async {
        signatures++;
        return 'signature';
      },
    );
    final rejected = expectLater(preparation, throwsStateError);
    authority.revoke();
    credential.complete(const OpenClawCredentials(
      deviceId: 'device',
      publicKey: 'public',
      token: 'secret',
    ));
    await rejected;
    expect(signatures, 0);
  });
  test('admission is not completion; unrelated and gapped events cannot settle',
      () {
    final source = OpenClawSource('original', Uri.parse('wss://example.test'));
    final turn = OpenClawTurn(
        source: source, sessionKey: 'agent:main:chat', inputId: 'input');
    turn.admit('run');
    expect(turn.state, OpenClawTurnState.admitted);
    expect(
        turn.accept(source, {
          'sessionKey': 'other',
          'runId': 'run',
          'seq': 1,
          'state': 'final'
        }),
        isFalse);
    expect(
        turn.accept(OpenClawSource('original', source.url), {
          'sessionKey': turn.sessionKey,
          'runId': 'run',
          'seq': 1,
          'state': 'final'
        }),
        isFalse);
    expect(
        turn.accept(source, {
          'sessionKey': turn.sessionKey,
          'runId': 'run',
          'seq': 1,
          'state': 'delta',
          'message': {
            'content': [
              {'type': 'text', 'text': 'hello'},
              {'type': 'thinking', 'thinking': 'private'}
            ]
          }
        }),
        isTrue);
    expect(turn.text, 'hello');
    turn.accept(source, {
      'sessionKey': turn.sessionKey,
      'runId': 'run',
      'seq': 1,
      'state': 'final'
    });
    expect(turn.state, OpenClawTurnState.streaming);
    turn.markEventGap();
    turn.accept(source, {
      'sessionKey': turn.sessionKey,
      'runId': 'run',
      'seq': 3,
      'state': 'final'
    });
    expect(turn.state, OpenClawTurnState.uncertain);
    expect(turn.needsHistory, isTrue);
    expect(turn.canResend, isFalse);
  });
  test('chat deltas replace snapshots and a final is authoritative', () {
    final source = OpenClawSource('a', Uri.parse('ws://127.0.0.1'));
    final turn = OpenClawTurn(source: source, sessionKey: 'key', inputId: 'id');
    turn.admit('run');
    for (final (seq, state, text) in [
      (4, 'delta', 'hel'),
      (5, 'delta', 'hello'),
      (6, 'final', 'hello!')
    ]) {
      turn.accept(source, {
        'sessionKey': 'key',
        'runId': 'run',
        'seq': seq,
        'state': state,
        'message': {
          'content': [
            {'type': 'text', 'text': text}
          ]
        }
      });
    }
    expect(turn.text, 'hello!');
    expect(turn.state, OpenClawTurnState.complete);
    turn.disconnected();
    expect(turn.state, OpenClawTurnState.complete);
  });
  test('disconnect before ACK stays uncertain with the original input identity',
      () {
    final source = OpenClawSource('a', Uri.parse('wss://example.test'));
    final turn =
        OpenClawTurn(source: source, sessionKey: 'key', inputId: 'same-id');
    turn.disconnected();
    expect(turn.state, OpenClawTurnState.uncertain);
    expect(turn.inputId, 'same-id');
    expect(turn.canResend, isFalse);
  });
}
