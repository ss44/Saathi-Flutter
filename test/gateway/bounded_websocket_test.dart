import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/bounded_websocket.dart';

const fixtureDirectory = 'test/gateway/fixtures';

List<int> frame(List<int> payload, {bool fin = true, int opcode = 2}) {
  final out = <int>[(fin ? 128 : 0) | opcode];
  if (payload.length < 126) {
    out.add(payload.length);
  } else if (payload.length <= 65535) {
    out.addAll([126, payload.length >> 8, payload.length & 255]);
  } else {
    out.add(127);
    out.addAll(
        (ByteData(8)..setUint64(0, payload.length)).buffer.asUint8List());
  }
  return [...out, ...payload];
}

class Fixture {
  Fixture(this.server, this.secure);
  final HttpServer server;
  final bool secure;
  final ready = Completer<Socket>();
  final peerClosed = Completer<void>();
  Socket? socket;
  final incoming = <int>[];
  final pong = Completer<List<int>>();
  void receive(List<int> bytes) {
    incoming.addAll(bytes);
    while (incoming.length >= 2) {
      final length = incoming[1] & 127;
      if (length > 125) throw StateError('Unexpected fixture client frame');
      final masked = incoming[1] & 128 != 0;
      final start = masked ? 6 : 2;
      if (incoming.length < start + length) return;
      if (incoming[0] & 15 == 10 && !pong.isCompleted) {
        pong.complete([
          for (var i = 0; i < length; i++)
            incoming[start + i] ^ (masked ? incoming[2 + i % 4] : 0),
        ]);
      }
      incoming.removeRange(0, start + length);
    }
  }

  HttpHeaders? requestHeaders;
  String get url => '${secure ? 'wss' : 'ws'}://127.0.0.1:${server.port}/';
  static Future<Fixture> start(
      {bool secure = false, bool badAccept = false}) async {
    final context = SecurityContext()
      ..useCertificateChain('$fixtureDirectory/localhost-test-cert.pem')
      ..usePrivateKey('$fixtureDirectory/localhost-test-key.pem');
    final server = secure
        ? await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context)
        : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = Fixture(server, secure);
    server.listen((request) async {
      fixture.requestHeaders = request.headers;
      request.response.statusCode = 101;
      request.response.headers
        ..set('Upgrade', 'websocket')
        ..set('Connection', 'Upgrade')
        ..set(
            'Sec-WebSocket-Accept',
            base64Encode(sha1
                .convert(utf8.encode(
                    '${request.headers.value('Sec-WebSocket-Key')}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
                .bytes));
      if (badAccept) {
        request.response.headers
            .set('Sec-WebSocket-Accept', base64Encode(Uint8List(20)));
      }
      if (request.headers.value('Sec-WebSocket-Protocol') != null) {
        request.response.headers.set('Sec-WebSocket-Protocol', 'fixture');
      }
      final socket = await request.response.detachSocket();
      fixture.socket = socket;
      unawaited(socket.done.catchError((Object _) {}));
      socket.listen(fixture.receive, onError: (Object _) {}, onDone: () {
        if (!fixture.peerClosed.isCompleted) fixture.peerClosed.complete();
      });
      fixture.ready.complete(socket);
    }, onError: (Object _) {});
    return fixture;
  }

  Future<void> close() async {
    socket?.destroy();
    await server.close(force: true);
  }
}

Future<void> expectRejected(List<int> bytes,
    {int maxBytes = 1024 * 1024,
    int maxFragments = 1024,
    bool split = false}) async {
  final fixture = await Fixture.start();
  final ws = await connectBoundedWebSocket(fixture.url,
      maxMessageBytes: maxBytes, maxMessageFragments: maxFragments);
  final done = Completer<void>();
  ws.listen((_) => fail('invalid/unfinished message emitted'),
      onError: (Object _) {}, onDone: done.complete);
  try {
    final raw = await fixture.ready.future;
    try {
      if (split) {
        for (final byte in bytes) {
          if (done.isCompleted) break;
          raw.add([byte]);
          await raw.flush();
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      } else {
        raw.add(bytes);
        await raw.flush();
      }
    } on SocketException {
      // Expected when rejection races the remaining queued attack bytes.
    }
    await done.future.timeout(const Duration(seconds: 2));
    await fixture.peerClosed.future.timeout(const Duration(seconds: 2));
    await raw.close().catchError((Object _) {});
  } finally {
    await fixture.close();
    await ws.close();
  }
}

void main() {
  setUp(() => HttpOverrides.global = null);

  test('disconnects eight nonfinal 512KiB fragments with 1MiB bound', () async {
    await expectRejected([
      for (var i = 0; i < 8; i++)
        ...frame(Uint8List(512 * 1024), fin: false, opcode: i == 0 ? 2 : 0),
    ]);
  });

  test('zero-length nonfinal flood is bounded by data-frame count', () async {
    await expectRejected([
      ...frame([], fin: false),
      for (var i = 0; i < 1024; i++) ...frame([], fin: false, opcode: 0),
    ]);
  });

  test('control interleave cannot reset aggregate bytes', () async {
    await expectRejected([
      ...frame([1, 2, 3, 4], fin: false),
      ...frame([1], opcode: 9),
      ...frame([1], fin: false, opcode: 0),
    ], maxBytes: 4);
  });

  test('control interleave cannot reset fragment count', () async {
    await expectRejected([
      ...frame([], fin: false),
      ...frame([], opcode: 9),
      ...frame([], fin: false, opcode: 0),
      ...frame([], opcode: 10),
      ...frame([], fin: false, opcode: 0),
    ], maxFragments: 2);
  });

  test('split extended header rejects declared length before payload',
      () async {
    await expectRejected([0x02, 126, 1, 0], maxBytes: 255, split: true);
  });

  test('split short continuation header rejects before any payload', () async {
    await expectRejected([
      ...frame([1, 2], fin: false),
      0,
      1,
    ], maxBytes: 2, split: true);
  });

  for (final length in [
    [0x80, 0, 0, 0, 0, 0, 0, 0],
    [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
    [0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
    [0, 0, 0, 0, 0, 0x10, 0, 1],
  ]) {
    test('64-bit oversized declaration $length needs no body', () async {
      await expectRejected([2, 127, ...length], split: true);
    });
  }

  test('64-bit declaration cannot overflow even at maximum signed-int budget',
      () async {
    await expectRejected([2, 127, ...List<int>.filled(8, 255)],
        maxBytes: 0x7fffffffffffffff, split: true);
  });

  test('nonempty controls preserve binary and exact pong before data FIN',
      () async {
    final fixture = await Fixture.start();
    final ws = await connectBoundedWebSocket(fixture.url);
    final messages = <dynamic>[];
    final received = Completer<void>();
    final subscription = ws.listen((message) {
      messages.add(message);
      received.complete();
    });
    try {
      final raw = await fixture.ready.future;
      raw.add([
        ...frame([1, 2], fin: false),
        ...frame([99, 0, 255], opcode: 9),
        ...frame([77], opcode: 10),
      ]);
      await raw.flush();
      expect(await fixture.pong.future.timeout(const Duration(seconds: 2)),
          [99, 0, 255]);
      expect(messages, isEmpty);
      raw.add(frame([3, 4], opcode: 0));
      await raw.flush();
      await received.future.timeout(const Duration(seconds: 2));
      expect(messages, [
        [1, 2, 3, 4]
      ]);
      await raw.close().catchError((Object _) {});
    } finally {
      await subscription.cancel();
      await fixture.close();
      await ws.close();
    }
  });

  test('fragmented UTF8, legal controls, split payload and multiple messages',
      () async {
    final fixture = await Fixture.start();
    final ws = await connectBoundedWebSocket(fixture.url,
        maxMessageBytes: 4,
        maxMessageFragments: 2,
        protocols: [
          'fixture'
        ],
        headers: {
          'Authorization': 'synthetic-token',
          'X-Fixture': ['one', 'two']
        });
    final messages = <dynamic>[];
    final received = Completer<void>();
    ws.listen((message) {
      messages.add(message);
      if (messages.length == 4) received.complete();
    });
    try {
      final raw = await fixture.ready.future;
      final bytes = [
        ...frame([0xf0, 0x9f], fin: false, opcode: 1),
        ...frame([42, 255], opcode: 9),
        ...frame([0x98, 0x80], opcode: 0),
        ...frame([42], opcode: 9),
        ...frame([1, 2], fin: false),
        ...frame([88], opcode: 10),
        ...frame([3, 4], opcode: 0),
        ...frame([], opcode: 1),
        ...frame(utf8.encode('next'), opcode: 1),
      ];
      for (final byte in bytes) {
        raw.add([byte]);
        await raw.flush();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await received.future.timeout(const Duration(seconds: 2));
      expect(messages, [
        '😀',
        [1, 2, 3, 4],
        '',
        'next'
      ]);
      expect(ws.protocol, 'fixture');
      expect(fixture.requestHeaders!.value('Authorization'), 'synthetic-token');
      expect(fixture.requestHeaders!.value('X-Fixture'), 'one, two');
      expect(fixture.requestHeaders!.value('Sec-WebSocket-Extensions'), isNull);
      await raw.close();
    } finally {
      await fixture.close();
      await ws.close();
    }
  });

  test('real TLS succeeds with explicitly trusted test CA', () async {
    final fixture = await Fixture.start(secure: true);
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('$fixtureDirectory/localhost-test-cert.pem');
    final ws =
        await connectBoundedWebSocket(fixture.url, securityContext: context);
    try {
      final message = ws.first;
      (await fixture.ready.future).add(frame(utf8.encode('TLS'), opcode: 1));
      expect(await message, 'TLS');
    } finally {
      await fixture.close();
      await ws.close();
    }
  });

  test('real TLS rejects untrusted test certificate', () async {
    final fixture = await Fixture.start(secure: true);
    try {
      await expectLater(connectBoundedWebSocket(fixture.url),
          throwsA(isA<HandshakeException>()));
      expect(fixture.ready.isCompleted, isFalse);
    } finally {
      await fixture.close();
    }
  });

  test('redirect never contacts a second authority', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var contacted = 0;
    target.listen((request) {
      contacted++;
      unawaited(request.response.close());
    });
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) {
      request.response.statusCode = 302;
      request.response.headers
          .set('Location', 'http://127.0.0.1:${target.port}/');
      unawaited(request.response.close());
    });
    try {
      await expectLater(
          connectBoundedWebSocket('ws://127.0.0.1:${origin.port}/',
              headers: {'Authorization': 'synthetic-secret'}),
          throwsA(isA<WebSocketException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(contacted, 0);
    } finally {
      await origin.close(force: true);
      await target.close(force: true);
    }
  });

  for (final cancellation in [false, true]) {
    test(
        '${cancellation ? 'cancellation' : 'timeout'} closes pending HTTP socket',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final gone = Completer<void>();
      server.listen((socket) {
        unawaited(socket.done.catchError((Object _) {}));
        socket.listen((_) {}, onError: (Object _) {}, onDone: gone.complete);
        accepted.complete(socket);
      });
      final cancel = Completer<void>();
      final future = connectBoundedWebSocket('ws://127.0.0.1:${server.port}/',
          connectTimeout: const Duration(milliseconds: 150),
          cancelSignal: cancellation ? cancel.future : null);
      final expected = expectLater(
          future,
          throwsA(cancellation
              ? isA<WebSocketException>()
              : isA<TimeoutException>()));
      final socket = await accepted.future;
      try {
        if (cancellation) cancel.complete();
        await expected;
        await gone.future.timeout(const Duration(seconds: 2));
      } finally {
        socket.destroy();
        await server.close();
      }
    });
  }

  for (final size in [126, 65536]) {
    test('accepts extended $size byte frame at exact aggregate bound',
        () async {
      final fixture = await Fixture.start();
      final ws = await connectBoundedWebSocket(fixture.url,
          maxMessageBytes: size + 1, maxMessageFragments: 2);
      final raw = await fixture.ready.future;
      try {
        final message = ws.first;
        final bytes = [
          ...frame(Uint8List(size), fin: false),
          ...frame([42], opcode: 0)
        ];
        // Split inside every byte of the extended length as well as the body.
        for (var offset = 0; offset < bytes.length;) {
          final next = offset < 10
              ? offset + 1
              : (offset + 257 < bytes.length ? offset + 257 : bytes.length);
          raw.add(bytes.sublist(offset, next));
          await raw.flush();
          offset = next;
        }
        final received =
            await message.timeout(const Duration(seconds: 2)) as List<int>;
        expect(received.length, size + 1);
        expect(received.last, 42);
        expect(received.take(size), everyElement(0));
      } finally {
        await fixture.close();
        await raw.close().catchError((Object _) {});
        await ws.close();
      }
    });
  }

  test('SDK rejects a wrong accept hash and closes detached socket', () async {
    final fixture = await Fixture.start(badAccept: true);
    try {
      await expectLater(connectBoundedWebSocket(fixture.url),
          throwsA(isA<WebSocketException>()));
      await fixture.peerClosed.future.timeout(const Duration(seconds: 2));
    } finally {
      await fixture.close();
    }
  });

  test('late connect cancellation does not revoke caller-owned socket',
      () async {
    final fixture = await Fixture.start();
    final cancel = Completer<void>();
    final ws =
        await connectBoundedWebSocket(fixture.url, cancelSignal: cancel.future);
    try {
      final message = ws.first;
      cancel.complete();
      await Future<void>.delayed(Duration.zero);
      (await fixture.ready.future).add(frame([42]));
      expect(await message.timeout(const Duration(seconds: 2)), [42]);
    } finally {
      await fixture.close();
      await ws.close();
    }
  });

  test('cancelling a returned WebSocket stream destroys its socket', () async {
    final fixture = await Fixture.start();
    final ws = await connectBoundedWebSocket(fixture.url);
    try {
      await ws.listen((_) {}).cancel();
      await fixture.peerClosed.future.timeout(const Duration(seconds: 2));
    } finally {
      await fixture.close();
      await ws.close();
    }
  });

  test('paused consumer resumes multiple complete messages in order', () async {
    final fixture = await Fixture.start();
    final ws = await connectBoundedWebSocket(fixture.url, maxMessageBytes: 4);
    final messages = <dynamic>[];
    final received = Completer<void>();
    final subscription = ws.listen((message) {
      messages.add(message);
      if (messages.length == 3) received.complete();
    });
    try {
      subscription.pause();
      final raw = await fixture.ready.future;
      raw.add([
        for (var i = 0; i < 3; i++) ...[
          ...frame([i], fin: false),
          ...frame([99], opcode: 9),
          ...frame([i + 1], opcode: 0),
        ]
      ]);
      await raw.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(messages, isEmpty);
      subscription.resume();
      await received.future.timeout(const Duration(seconds: 2));
      expect(messages, [
        [0, 1],
        [1, 2],
        [2, 3]
      ]);
      await raw.close().catchError((Object _) {});
    } finally {
      await subscription.cancel();
      await fixture.close();
      await ws.close();
    }
  });

  test('125-byte ping bypasses data byte cap unchanged before FIN', () async {
    final fixture = await Fixture.start();
    final ws = await connectBoundedWebSocket(fixture.url, maxMessageBytes: 1);
    final message = ws.first;
    try {
      final raw = await fixture.ready.future;
      final ping = List<int>.generate(125, (i) => i);
      raw.add([...frame([], fin: false), ...frame(ping, opcode: 9)]);
      await raw.flush();
      expect(
          await fixture.pong.future.timeout(const Duration(seconds: 2)), ping);
      raw.add(frame([42], opcode: 0));
      await raw.flush();
      expect(await message.timeout(const Duration(seconds: 2)), [42]);
      await raw.close().catchError((Object _) {});
    } finally {
      await fixture.close();
      await ws.close();
    }
  });

  final invalidFrames = <String, List<int>>{
    'masked server frame': [0x82, 0x80, 1, 2, 3, 4],
    'RSV1': [0xc2, 0],
    'RSV2': [0xa2, 0],
    'RSV3': [0x92, 0],
    'reserved data opcode': [0x83, 0],
    'reserved control opcode': [0x8b, 0],
    'fragmented ping': [0x09, 0],
    'oversized control': [0x89, 126, 0, 126],
    'nonminimal 16-bit': [0x82, 126, 0, 1, 42],
    'nonminimal 64-bit': [0x82, 127, 0, 0, 0, 0, 0, 0, 0, 1, 42],
    'orphan continuation': [0x80, 0],
    'nested data message': [...frame([], fin: false), ...frame([])],
    'one-byte close': [
      ...frame([42], opcode: 8)
    ],
    'invalid UTF8': [
      ...frame([0xf0], fin: false, opcode: 1),
      ...frame([99], opcode: 9),
      ...frame([0x28], opcode: 0)
    ],
  };
  for (final entry in invalidFrames.entries) {
    for (final split in [false, true]) {
      test('rejects ${entry.key}, split=$split and releases raw socket',
          () async {
        await expectRejected(entry.value, split: split);
      });
    }
  }

  test('close during unfinished data preserves SDK close code and reason',
      () async {
    final fixture = await Fixture.start();
    final ws = await connectBoundedWebSocket(fixture.url);
    final done = Completer<void>();
    ws.listen((_) => fail('unfinished message emitted'), onDone: done.complete);
    try {
      final raw = await fixture.ready.future;
      raw.add([
        ...frame([1, 2], fin: false),
        ...frame([3, 232, ...utf8.encode('bye')], opcode: 8)
      ]);
      await raw.flush();
      await done.future.timeout(const Duration(seconds: 2));
      expect(ws.closeCode, 1000);
      expect(ws.closeReason, 'bye');
      await raw.close().catchError((Object _) {});
    } finally {
      await fixture.close();
      await ws.close();
    }
  });

  test('cancel paused receive after unfinished data releases raw socket',
      () async {
    final fixture = await Fixture.start();
    final ws = await connectBoundedWebSocket(fixture.url);
    final subscription = ws.listen((_) => fail('unfinished message emitted'));
    try {
      final raw = await fixture.ready.future;
      raw.add(frame([1, 2], fin: false));
      await raw.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      subscription.pause();
      await subscription.cancel().timeout(const Duration(seconds: 2));
      await fixture.peerClosed.future.timeout(const Duration(seconds: 2));
      await raw.close().catchError((Object _) {});
    } finally {
      await fixture.close();
      await ws.close();
    }
  });

  test('EOF mid-header or mid-message never emits partial data', () async {
    for (final bytes in [
      [0x82, 126, 0],
      frame([1, 2], fin: false)
    ]) {
      final fixture = await Fixture.start();
      final ws = await connectBoundedWebSocket(fixture.url);
      final done = Completer<void>();
      ws.listen((_) => fail('partial message emitted'),
          onError: (Object _) {}, onDone: done.complete);
      try {
        final raw = await fixture.ready.future;
        raw.add(bytes);
        await raw.flush();
        await raw.close();
        await done.future.timeout(const Duration(seconds: 2));
      } finally {
        await fixture.close();
        await ws.close();
      }
    }
  });

  test('unsupported scheme and invalid bounds fail without connecting',
      () async {
    await expectLater(connectBoundedWebSocket('https://localhost/'),
        throwsA(isA<WebSocketException>()));
    await expectLater(
        connectBoundedWebSocket('ws://localhost/', maxMessageBytes: 0),
        throwsArgumentError);
  });
}
