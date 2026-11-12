import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/hermes_gateway.dart';

class Fixture {
  late HttpServer server;
  final requests = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];
  Map<String, dynamic> Function(Map<String, dynamic>)? respond;
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request,
          protocolSelector: (protocols) =>
              protocols.contains('hermes-gateway-v1')
                  ? 'hermes-gateway-v1'
                  : null);
      sockets.add(socket);
      socket.listen((frame) {
        final request = jsonDecode(frame as String) as Map<String, dynamic>;
        requests.add(request);
        final result = request['method'] == 'runtime.describe'
            ? {
                'profile_id': 'profile',
                'instance_id': 'owner',
                'authority_epoch': 3,
                'capabilities': ['durable-admission-v1', 'event-replay-v1']
              }
            : respond?.call(request) ?? {'sessions': <dynamic>[]};
        socket.add(jsonEncode(
            {'jsonrpc': '2.0', 'id': request['id'], 'result': result}));
      });
    });
  }

  GatewayGrant grant() => GatewayGrant(
        url: Uri.parse('ws://127.0.0.1:${server.port}/api/ws'),
        protocols: const ['hermes-gateway-v1', 'hermes-gateway-ticket.fixture'],
      );
  void event(
    String type,
    Map<String, dynamic> payload, {
    String session = 'chat',
    String admission = 'run',
    int generation = 4,
    int epoch = 3,
    int sequence = 1,
  }) =>
      sockets.last.add(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': type,
          'session_id': session,
          'admission_id': admission,
          'authority_epoch': epoch,
          'execution_generation': generation,
          'replay_epoch': 'replay',
          'seq': sequence,
          'payload': payload,
        }
      }));
  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

Map<String, dynamic> snapshot() => {
      'session_id': 'chat',
      'stored_session_id': 'chat',
      'messages': [
        {'role': 'user', 'content': 'Earlier input'},
        {
          'role': 'assistant',
          'content': 'Earlier reply',
          'reasoning': 'SECRET'
        },
        {'role': 'system', 'content': 'PRIVATE SYSTEM'},
        {'role': 'assistant', 'content': 'HIDDEN', 'display_kind': 'hidden'},
      ],
      'running': false,
      'authority_epoch': 3,
      'execution_generation': 4,
      'replay_epoch': 'replay',
      'last_sequence': 0,
      'pending': [],
      'prompts': [],
      'open_requests': [],
      'info': {},
    };

void main() {
  test('rejects insecure or ambiguous grants before dialing', () async {
    final grants = <GatewayGrant>[
      GatewayGrant(url: Uri.parse('ws://example.com/api/ws?token=secret')),
      GatewayGrant(url: Uri.parse('wss://user:secret@example.com/api/ws')),
      GatewayGrant(url: Uri.parse('wss://example.com/api/ws#secret')),
      GatewayGrant(
          url: Uri.parse('wss://example.com/api/ws'),
          protocols: const ['hermes-gateway-v1', 'hermes-gateway-v1']),
      GatewayGrant(
          url: Uri.parse('wss://example.com/api/ws'),
          protocols: const [
            'hermes-gateway-v1',
            'hermes-gateway-ticket.a',
            'hermes-gateway-ticket.b'
          ]),
      GatewayGrant(
          url: Uri.parse('wss://example.com/api/ws'),
          protocols: const ['hermes-gateway-v1', 'hermes-gateway-ticket.']),
    ];
    for (final grant in grants) {
      final client = HermesGatewayClient(
          grantProvider: () async => grant,
          requestTimeout: const Duration(milliseconds: 40));
      await expectLater(
          client.connect(),
          throwsA(isA<GatewayException>().having((e) => e.message,
              'safe validation message', 'Invalid or insecure gateway grant')));
      expect(client.state, GatewayConnectionState.disconnected);
      await client.dispose();
    }
  });
  test('caps list request window before any network request', () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    await client.connect();
    await expectLater(client.listSessions(limit: 201), throwsArgumentError);
    expect(fixture.requests, hasLength(1));
  });

  test('oversized inbound frames disconnect without exposing payload',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (_) => snapshot();
    final events = <GatewayEvent>[];
    client.events.listen(events.add);
    await client.connect();
    await client.attach('chat');
    fixture.event('message.delta', {'text': 'x' * (1024 * 1024 + 1)});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(client.state, GatewayConnectionState.disconnected);
    expect(events, isEmpty);
  });

  test('never follows WebSocket upgrade redirects to another origin', () async {
    final target = Fixture();
    await target.start();
    final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    redirect.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader,
          target.grant().url.replace(scheme: 'http').toString());
      await request.response.close();
    });
    final client = HermesGatewayClient(
        grantProvider: () async => GatewayGrant(
                url: Uri.parse(
                    'ws://127.0.0.1:${redirect.port}/api/ws?token=secret'),
                protocols: const [
                  'hermes-gateway-v1',
                  'hermes-gateway-ticket.secret'
                ]));
    addTearDown(() async {
      await client.dispose();
      await redirect.close(force: true);
      await target.close();
    });
    await expectLater(client.connect(), throwsA(isA<GatewayException>()));
    expect(target.sockets, isEmpty);
    expect(client.state, GatewayConnectionState.disconnected);
  });

  test('dispose cancels a pending grant without dialing or reopening state',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final grant = Completer<GatewayGrant>();
    final client = HermesGatewayClient(grantProvider: () => grant.future);
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    final connecting = client.connect();
    final rejected = expectLater(connecting, throwsA(isA<GatewayException>()));
    await client.dispose();
    grant.complete(fixture.grant());
    await rejected;
    expect(client.state, GatewayConnectionState.disposed);
    expect(fixture.sockets, isEmpty);
  });

  test('rejects an oversized server session window instead of mapping it',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (_) => {
          'sessions': List.generate(
              201, (i) => {'id': '$i', 'title': 'row', 'running': false})
        };
    await client.connect();
    await expectLater(client.listSessions(), throwsA(isA<GatewayException>()));
  });

  test('attach retains events racing the snapshot response', () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (_) {
      fixture.event('message.delta', {'text': 'after snapshot watermark'});
      return snapshot();
    };
    final events = <GatewayEvent>[];
    client.events.listen(events.add);
    await client.connect();
    await client.attach('chat');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.single.text, 'after snapshot watermark');
  });
  test('attach loads safe transcript and submits only new text to same owner',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (r) => r['method'] == 'session.resume'
        ? snapshot()
        : {
            'admission_id': 'run',
            'ref': {'profile_id': 'profile', 'session_id': 'chat'},
            'sequence': 1,
            'status': 'started',
            'outcome': null,
            'authority_epoch': 3,
            'execution_generation': 4,
          };
    await client.connect();
    final attached = await client.attach('chat');
    expect(attached.sessionId, 'chat');
    expect(attached.messages.map((m) => m.text),
        ['Earlier input', 'Earlier reply']);
    final run = await client.submit('Only new input', inputId: 'input-1');
    expect(run.admissionId, 'run');
    expect(run.state, GatewayRunState.running);
    expect(fixture.requests.last['method'], 'prompt.submit');
    expect(fixture.requests.last['params'], {
      'session_id': 'chat',
      'text': 'Only new input',
      'input_id': 'input-1',
    });
    expect(jsonEncode(fixture.requests.last), isNot(contains('Earlier')));
  });
  test(
      'terminal failure is not completion and stale or foreign events cannot own run',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (r) => r['method'] == 'session.resume'
        ? snapshot()
        : {
            'admission_id': 'run',
            'ref': {'profile_id': 'profile', 'session_id': 'chat'},
            'sequence': 1,
            'status': 'started',
            'outcome': null,
            'authority_epoch': 3,
            'execution_generation': 4,
          };
    final events = <GatewayEvent>[];
    client.events.listen(events.add);
    await client.connect();
    await client.attach('chat');
    final run = await client.submit('new', inputId: 'i');
    fixture.event('message.complete', {'text': 'foreign', 'status': 'complete'},
        admission: 'other');
    fixture.event('message.complete', {'text': 'stale', 'status': 'complete'},
        generation: 2, sequence: 2);
    fixture.event('reasoning.delta', {'text': 'PRIVATE'}, sequence: 3);
    fixture.event(
        'message.complete',
        {
          'text': 'partial',
          'status': 'error',
          'reasoning': 'PRIVATE',
          'error': 'unsafe credential details'
        },
        sequence: 4);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(run.state, GatewayRunState.failed);
    expect(events.where((e) => e.owned).single.state, GatewayRunState.failed);
    expect(events.map((e) => e.text), isNot(contains('PRIVATE')));
    expect(events.where((e) => e.type.startsWith('reasoning')), isEmpty);
  });

  test(
      'disconnect marks in-flight unknown and reconnect never replays submission',
      () async {
    final fixture = Fixture();
    await fixture.start();
    var grants = 0;
    final client = HermesGatewayClient(grantProvider: () async {
      grants++;
      return fixture.grant();
    });
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (r) => r['method'] == 'session.resume'
        ? snapshot()
        : {
            'admission_id': 'run',
            'ref': {'profile_id': 'profile', 'session_id': 'chat'},
            'sequence': 1,
            'status': r['method'] == 'prompt.receipt' ? 'terminal' : 'started',
            'outcome': r['method'] == 'prompt.receipt' ? 'failed' : null,
            'authority_epoch': 3,
            'execution_generation': 4,
          };
    await client.connect();
    await client.attach('chat');
    final run = await client.submit('one upload', inputId: 'i');
    await fixture.sockets.last.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.state, GatewayConnectionState.disconnected);
    expect(run.state, GatewayRunState.unknown);
    expect(client.attached, isNull);
    await client.connect();
    expect(grants, 2);
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
    expect(() => client.submit('not attached', inputId: 'j'),
        throwsA(isA<GatewayException>()));
    await client.attach('chat');
    expect((await client.refreshRun()).state, GatewayRunState.failed);
    expect(fixture.requests.last['params'],
        {'session_id': 'chat', 'admission_id': 'run'});
  });

  test(
      'queued input owns its generation even when completion precedes submit ACK',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (r) {
      if (r['method'] == 'session.resume') return snapshot();
      fixture.event('message.complete', {'text': 'done', 'status': 'complete'});
      return {
        'admission_id': 'run',
        'ref': {'profile_id': 'profile', 'session_id': 'chat'},
        'sequence': 1,
        'status': 'queued',
        'outcome': null,
        'authority_epoch': 3,
        'execution_generation': null
      };
    };
    final events = <GatewayEvent>[];
    client.events.listen(events.add);
    await client.connect();
    await client.attach('chat');
    final run = await client.submit('new', inputId: 'queued-1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(run.state, GatewayRunState.complete);
    expect(run.executionGeneration, 4);
    expect(events.single.owned, isTrue);
  });

  test(
      'event replay uses owner cursor and gap requires explicit snapshot reload',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (r) => r['method'] == 'session.resume'
        ? snapshot()
        : {
            'events': [],
            'latest_seq': 15,
            'last_sequence': 15,
            'epoch': 'new-epoch',
            'replay_epoch': 'new-epoch',
            'truncated': true,
            'snapshot_required': true,
            'count': 0,
          };
    await client.connect();
    await client.attach('chat');
    expect(await client.replayEvents(), isFalse);
    expect(client.needsResync, isTrue);
    expect(fixture.requests.last['method'], 'session.events.since');
    expect(fixture.requests.last['params'], {
      'session_id': 'chat',
      'last_sequence': 0,
      'replay_epoch': 'replay',
    });
    await expectLater(client.submit('blocked until resync', inputId: 'new'),
        throwsA(isA<GatewayException>()));
    await client.attach('chat');
    expect(client.needsResync, isFalse);
  });

  test(
      'replay deduplicates visible deltas and pending requests never auto-approve',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (r) {
      if (r['method'] == 'session.resume') {
        return {
          ...snapshot(),
          'prompts': [
            {
              'kind': 'approval',
              'prompt_id': 'p',
              'choices': ['once', 'deny']
            }
          ]
        };
      }
      return {
        'events': [
          {
            'type': 'message.delta',
            'session_id': 'chat',
            'replay_epoch': 'replay',
            'seq': 1,
            'payload': {'text': 'visible'}
          }
        ],
        'latest_seq': 1,
        'last_sequence': 1,
        'replay_epoch': 'replay',
        'truncated': false,
        'snapshot_required': false,
        'count': 1
      };
    };
    final events = <GatewayEvent>[];
    client.events.listen(events.add);
    await client.connect();
    expect((await client.attach('chat')).needsUserAction, isTrue);
    expect(await client.replayEvents(), isTrue);
    expect(await client.replayEvents(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.map((e) => e.text), ['visible']);
    expect(
        fixture.requests
            .where((r) => (r['method'] as String).contains('respond')),
        isEmpty);
  });

  test('negotiates canonical runtime and lists live sessions over real WS',
      () async {
    final fixture = Fixture();
    await fixture.start();
    final client =
        HermesGatewayClient(grantProvider: () async => fixture.grant());
    addTearDown(() async {
      await client.dispose();
      await fixture.close();
    });
    fixture.respond = (_) => {
          'sessions': [
            {
              'id': 'chat',
              'session_id': 'chat',
              'title': 'Existing desktop',
              'running': true
            }
          ],
          'scope': 'live'
        };
    await client.connect();
    expect(client.state, GatewayConnectionState.connected);
    final sessions = await client.listSessions();
    expect(sessions.single.id, 'chat');
    expect(sessions.single.title, 'Existing desktop');
    expect(fixture.requests.map((r) => r['method']),
        ['runtime.describe', 'session.list']);
    expect(fixture.requests.last['params'], {'scope': 'live', 'limit': 50});
  });
}
