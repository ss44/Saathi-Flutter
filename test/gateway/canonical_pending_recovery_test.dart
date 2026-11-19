import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';

import 'hermes_gateway_test.dart' show Fixture, snapshot;

void main() {
  test('late exact running receipt clears exhausted recovery presentation',
      () async {
    final fixture = Fixture();
    await fixture.start();
    fixture.dropSubmitAck = true;
    var recovered = false;
    final receipt = {
      'admission_id': 'recovered',
      'ref': {'session_id': 'chat', 'profile_id': 'profile'},
      'authority_epoch': 3,
      'execution_generation': 4,
      'status': 'started',
    };
    fixture.respond = (request) => request['method'] == 'prompt.receipt'
        ? receipt
        : {
            ...snapshot(),
            'pending': [
              if (recovered)
                {
                  ...receipt,
                  'input_id': fixture.requests.singleWhere(
                          (r) => r['method'] == 'prompt.submit')['params']
                      ['input_id'],
                }
            ],
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
    await expectLater(chat.send('hello'), throwsA(isA<GatewayException>()));
    expect(chat.problem, contains('Could not confirm'));
    recovered = true;
    await chat.refresh();
    expect(chat.pending, isTrue);
    expect(chat.problem, isNull);
    expect(chat.pendingStatus, 'Working on your reply');
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
  });
}
