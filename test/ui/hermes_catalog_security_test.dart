import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'controller_http_test.dart' show makeStore;

class DelayedSecrets extends MemorySecrets {
  Completer<String?>? gate;
  @override
  Future<String?> read(String id) => gate?.future ?? super.read(id);
}

void main() {
  for (final reason in ['key replacement', 'disposal', 'owner cancellation']) {
    test('$reason during secure read prevents all HTTP', () async {
      final base = await makeStore();
      final secrets = DelayedSecrets();
      final store =
          SaathiStore(preferences: base.preferences, secrets: secrets);
      var requests = 0;
      final controller = ChatController(store,
          coreFactory: () => SaathiCore(client: MockClient((r) async {
                requests++;
                return http.Response('{}', 200);
              })));
      await controller.load();
      await controller.addConnection(
          {'id': 'h', 'name': 'h', 'type': 'hermes', 'url': 'http://localhost'},
          'synthetic');
      secrets.gate = Completer<String?>();
      var owner = true;
      final pending = controller.discover(controller.connections.single,
          isCurrent: () => owner);
      final assertion = expectLater(pending, throwsStateError);
      if (reason == 'key replacement') {
        controller.connections[0] = {
          ...controller.connections.single,
          'authorityEpoch': 'replacement'
        };
      } else if (reason == 'disposal') {
        controller.dispose();
      } else {
        owner = false;
      }
      secrets.gate!.complete('old synthetic');
      await assertion;
      expect(requests, 0);
      if (reason != 'disposal') controller.dispose();
    });
  }

  test('revocation between capability and catalog prevents second HTTP',
      () async {
    var valid = true;
    var count = 0;
    final core = SaathiCore(client: MockClient((r) async {
      count++;
      valid = false;
      return http.Response(
          jsonEncode({
            'features': {'model_options': true},
            'endpoints': {
              'model_options': {'method': 'GET', 'path': '/api/model/options'}
            }
          }),
          200);
    }));
    core.addProvider(
        const ProviderConfig(id: 'h', name: 'h', type: ProviderType.hermes));
    await expectLater(
        core.discoverModels('h', isCurrent: () => valid), throwsStateError);
    expect(count, 1);
    core.close();
  });
  test('controller discards catalog after source key replacement and disposal',
      () async {
    final gate = Completer<http.Response>();
    final store = await makeStore();
    final controller = ChatController(store,
        coreFactory: () => SaathiCore(client: MockClient((r) async {
              if (r.url.path.endsWith('/capabilities')) {
                return http.Response(
                    '{"features":{"model_options":true},"endpoints":{"model_options":{"method":"GET","path":"/api/model/options"}}}',
                    200);
              }
              return gate.future;
            })));
    await controller.load();
    await controller.addConnection(
        {'id': 'h', 'name': 'h', 'type': 'hermes', 'url': 'http://localhost'},
        'old');
    final pending = controller.discover(controller.connections.single);
    final assertion = expectLater(pending, throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await controller.updateConnection(
        'h', {'name': 'h', 'type': 'hermes', 'url': 'http://localhost'},
        apiKey: 'new');
    controller.dispose();
    gate.complete(
        http.Response('{"providers":[{"slug":"one","models":["x"]}]}', 200));
    await assertion;
  });
  for (final scenario in [
    'missing',
    'denied',
    'malformed',
    'empty',
    'foreign'
  ]) {
    test('catalog $scenario is honest and never reads routing aliases',
        () async {
      final paths = <String>[];
      final core = SaathiCore(client: MockClient((r) async {
        paths.add(r.url.path);
        expect(r.followRedirects, false);
        if (r.url.path == '/v1/capabilities') {
          return http.Response(
              jsonEncode({
                'features': {'model_options': scenario != 'missing'},
                'endpoints': {
                  'model_options': {
                    'method': 'GET',
                    'path': scenario == 'foreign'
                        ? 'https://evil.invalid/models'
                        : '/api/model/options'
                  }
                }
              }),
              200);
        }
        if (scenario == 'denied') return http.Response('{}', 403);
        return http.Response(
            scenario == 'malformed'
                ? '{"providers":[{"slug":"one","models":[null]}]}'
                : '{"providers":[]}',
            200);
      }));
      core.addProvider(
          const ProviderConfig(id: 'h', name: 'h', type: ProviderType.hermes));
      if (scenario == 'empty') {
        expect(await core.discoverModels('h'), isEmpty);
      } else {
        await expectLater(
            core.discoverModels('h'), throwsA(isA<ProviderException>()));
      }
      expect(paths, isNot(contains('/v1/models')));
      core.close();
    });
  }
}
