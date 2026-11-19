import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_activity/activity_transport.dart';

void main() {
  test('public tool lifecycle survives SSE projection without private payloads',
      () async {
    final client = MockClient((_) async => http.Response(
        'id: 1\ndata: ${jsonEncode({
              'event': 'tool.started',
              'run_id': 'run_actual',
              'tool': 'search',
              'preview': 'PRIVATE',
              'arguments': 'PRIVATE',
              'error': 'PRIVATE fixture',
            })}\n\n',
        200,
        headers: {'content-type': 'text/event-stream'}));
    final transport = ActivityTransport(
        origin: Uri.parse('https://host'),
        bearerKey: 'fixture',
        isCurrent: () => true,
        eventsSupported: true,
        client: client);
    final events = <ActivityTransportEvent>[];
    final done = Completer<void>();
    transport
        .connect('run_actual')
        .listen(events.add, onError: (Object _) {}, onDone: done.complete);
    await done.future;
    expect(events.single.data['tool'], 'search');
    expect(events.single.data.containsKey('preview'), isFalse);
    expect(events.single.data.containsKey('arguments'), isFalse);
    expect(events.single.data.containsKey('error'), isFalse);
    await transport.close();
    client.close();
  });
  test('localhost valid activity outlives deadline then idle disconnects',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = http.Client();
    final timers = <Timer>[];
    HttpResponse? response;
    server.listen((r) async {
      response = r.response;
      r.response.bufferOutput = false;
      r.response.headers.contentType = ContentType('text', 'event-stream');
      var sequence = 0;
      timers.add(Timer.periodic(const Duration(milliseconds: 300), (timer) {
        r.response.write('id: $sequence\ndata: ${jsonEncode({
              'event': 'message.delta',
              'run_id': 'run_actual',
              'delta': 'visible',
              'reasoning': 'PRIVATE',
              'seq': sequence++
            })}\n\n');
        unawaited(r.response.flush());
        if (sequence == 8) timer.cancel();
      }));
    });
    final transport = ActivityTransport(
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        bearerKey: 'private',
        isCurrent: () => true,
        eventsSupported: true,
        idleTimeout: const Duration(seconds: 2),
        client: client);
    final events = <ActivityTransportEvent>[];
    final done = Completer<void>();
    final errors = <Object>[];
    transport
        .connect('run_actual')
        .listen(events.add, onError: errors.add, onDone: done.complete);
    await done.future.timeout(const Duration(seconds: 8));
    expect(events, hasLength(8));
    expect(events.first.data['delta'], 'visible');
    expect(events.first.data.containsKey('reasoning'), isFalse);
    expect(errors, hasLength(1));
    await transport.close();
    for (final timer in timers) {
      timer.cancel();
    }
    await response?.close();
    client.close();
    await server.close(force: true);
  });
  test('abort before listening releases attachment without reviving old stream',
      () async {
    var calls = 0;
    final t = ActivityTransport(
        origin: Uri.parse('https://example.test'),
        bearerKey: 'private',
        isCurrent: () => true,
        eventsSupported: true,
        client: MockClient((_) async {
          calls++;
          return http.Response('', 200);
        }));
    final old = t.connect('run_actual');
    await t.abort();
    final fresh = t.connect('run_actual');
    await expectLater(old, emitsError(isStateError));
    await expectLater(fresh, emitsError(isStateError));
    expect(calls, 1);
    await t.close();
  });
  test('localhost split UTF8 CRLF heartbeat streams incrementally and aborts',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = http.Client();
    final received = Completer<void>();
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer private');
      request.response.bufferOutput = false;
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      final bytes = utf8.encode(
          ': heartbeat\r\n\r\nid: 9\r\ndata: {"event":"subagent.start","run_id":"run_actual","seq":9,"goal":"héllo"}\r\n\r\n');
      final split = bytes.indexOf(0xc3) + 1;
      request.response.add(bytes.sublist(0, split));
      await request.response.flush();
      request.response.add(bytes.sublist(split));
      await request.response.flush();
    });
    final t = ActivityTransport(
        origin: Uri.parse('http://127.0.0.1:${server.port}'),
        bearerKey: 'private',
        isCurrent: () => true,
        eventsSupported: true,
        client: client);
    final errors = <Object>[];
    final done = Completer<void>();
    t.connect('run_actual').listen((e) {
      expect(e.data['goal'], 'héllo');
      received.complete();
    }, onError: (Object e) {
      errors.add(e);
      if (!received.isCompleted) received.completeError(e);
    }, onDone: done.complete);
    await received.future.timeout(const Duration(seconds: 5),
        onTimeout: () => throw StateError('no event'));
    await t.abort().timeout(const Duration(seconds: 5),
        onTimeout: () => throw StateError('abort hung'));
    await done.future.timeout(const Duration(seconds: 5),
        onTimeout: () => throw StateError('no done'));
    expect(t.cursor, '9');
    expect(errors, isNotEmpty);
    await t.close();
    client.close();
    await server.close(force: true);
  });
  test('unsafe scope capability and obsolete authority make no requests',
      () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('', 200);
    });
    ActivityTransport make(
            {String origin = 'https://example.test',
            String? profile,
            bool supported = true,
            bool current = true}) =>
        ActivityTransport(
            origin: Uri.parse(origin),
            profile: profile,
            bearerKey: 'private',
            isCurrent: () => current,
            eventsSupported: supported,
            client: client);
    for (final origin in [
      'http://example.test',
      'https://u:p@example.test',
      'https://example.test/path',
      'https://example.test?x=1'
    ]) {
      expect(() => make(origin: origin), throwsArgumentError);
    }
    expect(() => make(profile: '../x'), throwsArgumentError);
    expect(
        () => make(supported: false).connect('run_actual'), throwsStateError);
    expect(() => make(current: false).connect('run_actual'), throwsStateError);
    expect(() => make().connect('../bad'), throwsArgumentError);
    expect(() => make().connect('run_actual', lastEventId: '1\r\nx:y'),
        throwsArgumentError);
    expect(calls, 0);
  });
  test('rejects redirects malformed JSON scope mismatch and bounded frames',
      () async {
    for (final payload in [
      'data: not-json\n\n',
      'data: {"event":"x","run_id":"foreign"}\n\n',
      'data: ${'x' * 200}\n\n',
      (':x\n' * 100)
    ]) {
      final t = ActivityTransport(
          origin: Uri.parse('https://example.test'),
          bearerKey: 'private',
          isCurrent: () => true,
          eventsSupported: true,
          maxLine: 128,
          maxFrame: 128,
          client: MockClient((_) async => http.Response(payload, 200,
              headers: {'content-type': 'text/event-stream'})));
      await expectLater(t.connect('run_actual'), emitsError(isStateError));
      await t.close();
    }
    var calls = 0;
    final t = ActivityTransport(
        origin: Uri.parse('https://example.test'),
        bearerKey: 'private',
        isCurrent: () => true,
        eventsSupported: true,
        client: MockClient((r) async {
          calls++;
          expect(r.followRedirects, isFalse);
          return http.Response('', 302,
              headers: {'location': 'https://other.test'});
        }));
    await expectLater(t.connect('run_actual'), emitsError(isStateError));
    expect(calls, 1);
    await t.close();
  });
  test(
      'lost authority after send and cancellation of pending send emit no events',
      () async {
    var current = true;
    final response = Completer<http.Response>();
    final t = ActivityTransport(
        origin: Uri.parse('https://example.test'),
        bearerKey: 'private',
        isCurrent: () => current,
        eventsSupported: true,
        client: MockClient((_) => response.future));
    final result =
        expectLater(t.connect('run_actual'), emitsError(isStateError));
    await Future<void>.delayed(Duration.zero);
    current = false;
    response.complete(http.Response('data: {}\n\n', 200,
        headers: {'content-type': 'text/event-stream'}));
    await result;
    await t.close();
    final pending = Completer<http.Response>();
    final a = ActivityTransport(
        origin: Uri.parse('https://example.test'),
        bearerKey: 'private',
        isCurrent: () => true,
        eventsSupported: true,
        client: MockClient((_) => pending.future));
    final stopped =
        expectLater(a.connect('run_actual'), emitsError(isStateError));
    await Future<void>.delayed(Duration.zero);
    await a.close();
    await stopped;
    pending.complete(http.Response('', 200));
    expect(() => a.connect('run_actual'), throwsStateError);
  });
  test('canonical JSON SSE cursor auth profile and reconnect header', () async {
    final requests = <http.Request>[];
    final t = ActivityTransport(
        origin: Uri.parse('https://example.test'),
        profile: 'work',
        bearerKey: 'private',
        isCurrent: () => true,
        eventsSupported: true,
        client: MockClient((r) async {
          requests.add(r);
          return http.Response(
              ': heartbeat\n\nid: 7\ndata: {"event":"subagent.start",\ndata: "run_id":"run_actual","seq":7,"goal":"héllo","reasoning":"never"}\n\n',
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'});
        }));
    final events = <ActivityTransportEvent>[];
    final errors = <Object>[];
    await t
        .connect('run_actual')
        .listen(events.add, onError: errors.add)
        .asFuture<void>()
        .catchError((Object e) {
      errors.add(e);
    });
    expect(events.single.data['goal'], 'héllo');
    expect(events.single.data.containsKey('reasoning'), isFalse);
    expect(t.cursor, '7');
    expect(requests.single.url.path, '/p/work/v1/runs/run_actual/events');
    expect(requests.single.headers['Authorization'], 'Bearer private');
    expect(requests.single.followRedirects, isFalse);
    expect(errors, isNotEmpty);
    await t
        .connect('run_actual', lastEventId: t.cursor)
        .drain<void>()
        .catchError((Object _) {});
    expect(requests.last.headers['Last-Event-ID'], '7');
    await t.close();
  });
}
