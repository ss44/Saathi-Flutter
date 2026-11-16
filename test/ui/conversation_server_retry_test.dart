import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/conversation_servers.dart';

void main() {
  for (final refreshFailure in [true, false]) {
    testWidgets(
        'Try again retries failed ${refreshFailure ? 'refresh at zero and replaces stale pages' : 'pagination at the failed offset'}',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final offsets = <int>[];
      var fail = false;
      var recovered = false;
      final controller = ChatController(
          SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: MemorySecrets()),
          coreFactory: () => SaathiCore(client: MockClient((request) async {
                if (request.url.path == '/v1/capabilities') {
                  return http.Response('{}', 200);
                }
                final offset =
                    int.parse(request.url.queryParameters['offset']!);
                offsets.add(offset);
                if (fail) return http.Response('failed', 500);
                return http.Response(
                    jsonEncode({
                      'data': [
                        {
                          'id': recovered ? 'fresh' : 'old-$offset',
                          'title': recovered ? 'Fresh chat' : 'Old $offset'
                        }
                      ],
                      'offset': offset,
                      'limit': 50,
                      'has_more': true
                    }),
                    200);
              })));
      final connection = <String, dynamic>{
        'id': 'home',
        'name': 'Home',
        'type': 'hermes',
        'url': 'https://retry.test'
      };
      controller.connections.add(connection);
      final cache = ConversationServerCache(controller, connection);
      addTearDown(() {
        cache.dispose();
        controller.dispose();
      });
      await tester.runAsync(() async {
        await cache.load();
        await cache.load();
      });
      expect(offsets, [0, 50]);
      expect(cache.sessions.map((s) => s.id), ['old-0', 'old-50']);
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: ConversationServer(cache: cache))));
      fail = true;
      if (refreshFailure) {
        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('Refresh'));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      } else {
        await tester.runAsync(() => cache.load());
      }
      await tester.pumpAndSettle();
      expect(cache.failed, isTrue);
      expect(cache.sessions.map((s) => s.id), ['old-0', 'old-50']);
      fail = false;
      recovered = true;
      await tester.runAsync(() async {
        await tester.tap(find.text('Try again'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(
          offsets, [0, 50, refreshFailure ? 0 : 100, refreshFailure ? 0 : 100]);
      expect(cache.failed, isFalse);
      expect(cache.sessions.map((s) => s.id),
          refreshFailure ? ['fresh'] : ['old-0', 'old-50', 'fresh']);
      expect(find.text('Fresh chat'), findsOneWidget);
      expect(
          find.text('Old 0'), refreshFailure ? findsNothing : findsOneWidget);
    });
  }
}
