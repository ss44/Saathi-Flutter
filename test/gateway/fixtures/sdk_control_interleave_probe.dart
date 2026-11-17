// Opt-in diagnostic: intentionally exits 1 while the direct SDK defect exists.
// Default acceptance coverage is in bounded_websocket_test.dart.
// The normalized transport must preserve data despite the direct SDK defect.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:saathi/gateway/bounded_websocket.dart';

Future<void> main() async {
  for (final bounded in [false, true]) {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Socket? peer;
    server.listen((request) async {
      request.response.statusCode = 101;
      request.response.headers
        ..set('Connection', 'Upgrade')
        ..set('Upgrade', 'websocket')
        ..set(
            'Sec-WebSocket-Accept',
            base64Encode(sha1
                .convert(utf8.encode(
                    '${request.headers.value('Sec-WebSocket-Key')}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
                .bytes));
      peer = await request.response.detachSocket();
      unawaited(peer!.done.catchError((Object _) {}));
      peer!.listen((_) {}, onError: (Object _) {});
      // Nonfinal binary [1,2], legal ping [99], final continuation [3,4].
      peer!.add([0x02, 2, 1, 2, 0x89, 1, 99, 0x80, 2, 3, 4]);
    });
    final url = 'ws://127.0.0.1:${server.port}/';
    final socket = bounded
        ? await connectBoundedWebSocket(url)
        : await WebSocket.connect(url,
            compression: CompressionOptions.compressionOff);
    try {
      final message = await socket.first.timeout(const Duration(seconds: 2));
      stdout.writeln(
          '${bounded ? 'normalized transport' : 'direct official SDK diagnostic'} message=$message; RFC expected=[1, 2, 3, 4]');
      if (jsonEncode(message) != '[1,2,3,4]') exitCode = 1;
    } finally {
      peer?.destroy();
      await socket.close();
      await server.close(force: true);
    }
  }
}
