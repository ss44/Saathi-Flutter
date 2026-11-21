import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_activity/activity_owner.dart';
import 'package:saathi/agent_activity/activity_model.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import '../agent_runs_test.dart' show capabilities;

class HeldSecrets extends MemorySecrets {
  bool hold = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<String?> read(String id) async {
    if ((id == 'h' || id.startsWith('credential.v1.')) && hold) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.read(id);
  }
}

void main() {
  // These tests exercise the retained desktop SSE credential boundary.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  test('authoritative status maps answer-needed and unknown honestly', () {
    expect(ActivityOwner.status('waiting_for_approval'),
        ActivityStatus.waitingApproval);
    expect(ActivityOwner.status('answer_needed'), ActivityStatus.answerNeeded);
    expect(ActivityOwner.status('waiting_for_answer'),
        ActivityStatus.answerNeeded);
    expect(ActivityOwner.status('queued'), ActivityStatus.queued);
    expect(ActivityOwner.status('running'), ActivityStatus.running);
    expect(ActivityOwner.status('stopping'), ActivityStatus.stopping);
    expect(ActivityOwner.status('interrupted'), ActivityStatus.interrupted);
    expect(ActivityOwner.status('future_status'), ActivityStatus.unknown);
  });
  for (final rotated in [false, true]) {
    for (final revoke in [
      'none',
      'owner',
      'controller',
      'background',
      'source',
      'session'
    ]) {
      test(
          '$revoke during delayed telemetry secret read keeps event authority (rotated=$rotated)',
          () async {
        SharedPreferences.setMockInitialValues({});
        final secrets = HeldSecrets();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var gets = 0;
        server.listen((r) async {
          gets++;
          expect(r.headers.value(HttpHeaders.authorizationHeader),
              'Bearer ${rotated ? 'rotated-private' : 'private'}');
          await r.response.close();
        });
        final c = ChatController(
            SaathiStore(
                preferences: await SharedPreferences.getInstance(),
                secrets: secrets),
            runClientFactory: (root, key) =>
                RunClient(root, key, client: MockClient((r) async {
                  if (r.url.path.endsWith('capabilities')) {
                    return http.Response(
                        jsonEncode({
                          ...capabilities,
                          'features': {
                            ...capabilities['features'] as Map,
                            'run_events_sse': true
                          },
                          'endpoints': {
                            ...capabilities['endpoints'] as Map,
                            'run_events': {
                              'method': 'GET',
                              'path': '/v1/runs/{run_id}/events'
                            }
                          }
                        }),
                        200);
                  }
                  if (r.method != 'POST') secrets.hold = true;
                  return http.Response('{"run_id":"run_1","status":"running"}',
                      r.method == 'POST' ? 202 : 200);
                })));
        await c.load();
        await c.addConnection({
          'id': 'h',
          'name': 'H',
          'type': 'hermes',
          'url': 'http://127.0.0.1:${server.port}'
        }, 'private');
        if (rotated) {
          await c.store.changeConnection('h',
              replacement: c.connections.single, apiKey: 'rotated-private');
        }
        await c.newSession(c.connections.single, 'model', '');
        final owner = ActivityOwner(c);
        expect(await c.send('work'), true);
        await secrets.entered.future.timeout(const Duration(seconds: 2));
        switch (revoke) {
          case 'none':
            break;
          case 'owner':
            owner.dispose();
          case 'controller':
            c.dispose();
          case 'background':
            owner.setPaused(true);
            c.pauseRuns(true);
          case 'source':
            c.connections[0] = {...c.connections.single};
            c.notifyListeners();
          case 'session':
            c.sessions.clear();
            c.notifyListeners();
        }
        secrets.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(gets, revoke == 'none' ? 1 : 0);
        owner.dispose();
        if (revoke != 'controller') c.dispose();
        await server.close(force: true);
      });
    }
  }
}
