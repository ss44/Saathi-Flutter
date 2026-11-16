import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/conversation_servers.dart';
import 'remote_lifecycle_test.dart' show DelayedSecrets, TrackedCore;

void main() {
  test(
      'server caches isolate same IDs, preserve order, dedupe pages and retain titles during refresh',
      () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    Completer<http.Response>? refresh;
    final c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()),
        coreFactory: () => SaathiCore(client: MockClient((r) async {
              requests.add(r);
              if (r.url.path == '/v1/capabilities') {
                return http.Response('{}', 200);
              }
              if (r.url.host == 'bad.test') {
                return http.Response('PRIVATE TOKEN', 500);
              }
              if (refresh != null) return refresh.future;
              final offset = int.parse(r.url.queryParameters['offset']!);
              return http.Response(
                  jsonEncode({
                    'data': [
                      {'id': 'same', 'title': r.url.host},
                      if (offset > 0) {'id': 'next', 'title': 'Older'}
                    ],
                    'offset': offset,
                    'limit': 50,
                    'has_more': offset == 0
                  }),
                  200);
            })));
    final connections = [
      for (final host in ['one.test', 'two.test', 'bad.test'])
        <String, dynamic>{
          'id': host,
          'name': host,
          'type': 'hermes',
          'url': 'https://$host'
        }
    ];
    c.connections.addAll(connections);
    final caches = [
      for (final connection in connections)
        ConversationServerCache(c, connection)
    ];
    await Future.wait(caches.map((cache) => cache.load()));
    expect(caches[0].sessions.single.title, 'one.test');
    expect(caches[1].sessions.single.title, 'two.test');
    expect(caches[2].failed, isTrue);
    await caches[0].load();
    expect(caches[0].sessions.map((s) => s.id), ['same', 'next']);
    refresh = Completer<http.Response>();
    final pending = caches[0].load(refresh: true);
    await Future<void>.delayed(Duration.zero);
    final before = requests.length;
    await caches[0].load(refresh: true);
    expect(requests.length, before);
    expect(caches[0].sessions.length, 2);
    refresh.complete(http.Response('{"data":[],"has_more":false}', 200));
    await pending;
    expect(caches[0].sessions, isEmpty);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    for (final cache in caches) {
      cache.dispose();
    }
    c.dispose();
  });
  for (final action in ['dispose', 'replace', 'delete']) {
    test('drawer delayed secret $action never starts network', () async {
      SharedPreferences.setMockInitialValues({});
      final secrets = DelayedSecrets();
      var requests = 0;
      final core = TrackedCore(MockClient((r) async {
        requests++;
        return http.Response('{}', 200);
      }));
      final c = ChatController(
          SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: secrets),
          coreFactory: () => core);
      final connection = <String, dynamic>{
        'id': 'h',
        'name': 'Home',
        'type': 'hermes',
        'url': 'https://one.test'
      };
      c.connections.add(connection);
      final cache = ConversationServerCache(c, connection);
      final pending = cache.load();
      if (action == 'dispose') cache.dispose();
      if (action == 'replace') c.connections[0] = {...connection};
      if (action == 'delete') c.connections.clear();
      secrets.pending.complete('test');
      await pending;
      expect(requests, 0);
      expect(core.closed, isTrue);
      expect(cache.sessions, isEmpty);
      if (action != 'dispose') cache.dispose();
      c.dispose();
    });
  }
}
