import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/ui/chat_controller.dart';

import 'canonical_combined_controller_test.dart' show setup;

void main() {
  for (final mismatch in [
    'profile',
    'legacy profile',
    'connection',
    'session'
  ]) {
    test('targeted reconnect rejects $mismatch before native resume', () async {
      final (c, host, _) = await setup();
      final original = c.current!;
      final expected = ChatSession(
        id: 'other',
        connectionId: mismatch == 'connection' ? 'other' : 'native',
        remoteSessionId: mismatch == 'session' ? 'other' : 'chat',
        canonicalProfileId: mismatch == 'legacy profile'
            ? null
            : mismatch == 'profile'
                ? 'other'
                : 'profile',
        model: 'Server model',
      );
      c.sessions.add(expected);
      final before = host.requests.length;
      await expectLater(
          c.attachCanonical(GatewaySession({'session_id': 'chat'}),
              expectedSession: expected),
          throwsStateError);
      expect(c.current, same(original));
      expect(host.requests, hasLength(before));
      expect(c.current!.messages.first.content, 'Earlier input');
    });
  }

  test('revocation after native resume cannot retain send authority', () async {
    final (c, host, _) = await setup();
    final original = c.current;
    final resumes =
        host.requests.where((r) => r['method'] == 'session.resume').length;
    await expectLater(
        c.attachCanonical(GatewaySession({'session_id': 'chat'}),
            isOwnerCurrent: () =>
                host.requests
                    .where((r) => r['method'] == 'session.resume')
                    .length ==
                resumes),
        throwsStateError);
    expect(c.current, same(original));
    expect(c.readOnly, isTrue);
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
  });

  test('closed attachment route cannot resume or select a session', () async {
    final (c, host, _) = await setup();
    final original = c.current;
    final before = host.requests.length;
    await expectLater(
        c.attachCanonical(GatewaySession({'session_id': 'chat'}),
            isOwnerCurrent: () => false),
        throwsStateError);
    expect(c.current, same(original));
    expect(host.requests, hasLength(before));
  });
}
