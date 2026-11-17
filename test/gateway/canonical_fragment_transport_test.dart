import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'bounded_websocket_test.dart' show frame;

Future<(HttpServer, Socket, HermesGatewayClient)> rawClient() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final peer = Completer<Socket>();
  server.listen((request) async {
    request.response.statusCode = 101;
    request.response.headers
      ..set('Upgrade', 'websocket')
      ..set('Connection', 'Upgrade')
      ..set('Sec-WebSocket-Protocol', 'hermes-gateway-v1')
      ..set(
          'Sec-WebSocket-Accept',
          base64Encode(sha1
              .convert(utf8.encode(
                  '${request.headers.value('Sec-WebSocket-Key')}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
              .bytes));
    final socket = await request.response.detachSocket();
    var described = false;
    socket.listen((_) {
      if (described) return;
      described = true;
      socket.add(frame(
          utf8.encode(jsonEncode({
            'jsonrpc': '2.0',
            'id': 'saathi-1',
            'result': {
              'capabilities': ['durable-admission-v1', 'session-transcript-v1'],
              'profile_id': 'profile',
              'instance_id': 'instance'
            }
          })),
          opcode: 1));
    }, onError: (Object _) {});
    peer.complete(socket);
  });
  final client = HermesGatewayClient(
      grantProvider: () async =>
          GatewayGrant(url: Uri.parse('ws://127.0.0.1:${server.port}/api/ws')));
  await client.connect();
  return (server, await peer.future, client);
}

void main() {
  test(
      'actual canonical client rejects cumulative nonfinal fragments before FIN',
      () async {
    final (server, peer, client) = await rawClient();
    addTearDown(() async {
      await peer.close().catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await client.dispose();
      peer.destroy();
      await server.close(force: true);
    });
    final payload = List<int>.filled(512 * 1024, 32);
    for (var i = 0; i < 8; i++) {
      peer.add(frame(payload, fin: false, opcode: i == 0 ? 1 : 0));
    }
    await peer.flush();
    for (var i = 0;
        i < 100 && client.state == GatewayConnectionState.connected;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(client.state, GatewayConnectionState.disconnected,
        reason:
            'No FIN was sent. SDK per-frame limits and post-string checks cannot protect this path.');
  });
  test('actual canonical client preserves fragmented RPC around nonempty ping',
      () async {
    final (server, peer, client) = await rawClient();
    addTearDown(() async {
      await peer.close().catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await client.dispose();
      peer.destroy();
      await server.close(force: true);
    });
    final listing = client.listSessions();
    final bytes = utf8.encode(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'saathi-2',
      'result': {
        'sessions': [
          {'session_id': 'original', 'title': 'Original session'}
        ]
      }
    }));
    final split = bytes.length ~/ 2;
    peer.add(frame(bytes.sublist(0, split), fin: false, opcode: 1));
    peer.add(frame([99, 0, 255], opcode: 9));
    peer.add(frame(bytes.sublist(split), opcode: 0));
    await peer.flush();
    expect((await listing).single.id, 'original');
  });
}
