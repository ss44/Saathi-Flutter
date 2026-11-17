import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'gateway/canonical_combined_controller_test.dart' as fixture;
import 'gateway/hermes_gateway_test.dart' show snapshot;

class TranscriptHost extends fixture.NativeHost {
  final rows = <Map<String, dynamic>>[
    {'row_kind': 'message', 'row_id': 1, 'role': 'user', 'text': 'Old input'},
    {
      'row_kind': 'message',
      'row_id': 2,
      'role': 'assistant',
      'text': 'Old reply'
    },
  ];
  @override
  Future<void> start() async {
    const cert = 'test/gateway/fixtures/localhost-test-cert.pem';
    SecurityContext.defaultContext.setTrustedCertificates(cert);
    final tls = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey('test/gateway/fixtures/localhost-test-key.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request,
          protocolSelector: (_) => 'hermes-gateway-v1');
      sockets.add(ws);
      ws.listen((raw) {
        final rpc = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(rpc);
        final params = rpc['params'] as Map;
        final Map<String, dynamic> value;
        switch (rpc['method']) {
          case 'runtime.describe':
            value = {
              'profile_id': 'profile',
              'instance_id': 'owner',
              'authority_epoch': 3,
              'capabilities': [
                'durable-admission-v1',
                'event-replay-v1',
                'session-transcript-v1'
              ]
            };
          case 'session.list':
            value = {
              'sessions': [
                {'session_id': 'chat', 'title': 'Native A'}
              ]
            };
          case 'session.resume':
            value = {...snapshot(), 'running': true};
          case 'session.transcript':
            final offset =
                int.tryParse(params['cursor'] as String? ?? '0') ?? 0;
            value = {
              'session_id': 'chat',
              'rows': rows.skip(offset).toList(),
              'reset': false,
              'next_cursor': '${rows.length}'
            };
          default:
            value = receipt();
        }
        ws.add(
            jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], 'result': value}));
      });
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final kind in ['tool', 'compaction', 'empty assistant']) {
    test('$kind is not a completed native answer or unread reply', () async {
      final host = TranscriptHost();
      await host.start();
      SharedPreferences.setMockInitialValues({});
      final c = ChatController(SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets()));
      addTearDown(() async {
        c.dispose();
        await host.close();
      });
      await c.load();
      await c.addConnection({
        'id': 'native',
        'name': 'Native',
        'type': 'hermesGateway',
        'url': host.url
      }, '');
      await c.connectCanonical(c.connections.single, host.invite);
      await c.attachCanonical(
          GatewaySession({'session_id': 'chat', 'title': 'A'}));
      final a = c.current!;
      final b = ChatSession(id: 'B', connectionId: 'native', model: 'other');
      c.sessions.add(b);
      c.select(b);
      host.rows.add(switch (kind) {
        'tool' => {
            'row_kind': 'message',
            'row_id': 3,
            'role': 'tool',
            'name': 'read_file',
            'text': 'not an answer'
          },
        'compaction' => {
            'row_kind': 'compaction',
            'row_id': 3,
            'text': 'Retained context summary'
          },
        _ => {
            'row_kind': 'message',
            'row_id': 3,
            'role': 'assistant',
            'text': ''
          },
      });
      await c.refreshCanonical();
      final entry = c.organization.entry(c.identityOf(a));
      stdout.writeln(
          'REPRO kind=$kind pending=${c.workState(a)} unread=${entry.unread} completions=${entry.completions} text=${a.messages.last.content}');
      expect(entry.completions, isEmpty,
          reason:
              'Only actual completed answer bodies may create unread completion identities');
    });
  }
}
