import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/remote_sessions.dart';

import 'remote_history_test_driver.dart';

void main() {
  testWidgets('source history envelope without has_more reaches newer messages',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final offsets = <int>[];
    final requests = <http.Request>[];
    final controller = ChatController(store,
        coreFactory: () => SaathiCore(client: MockClient((request) async {
              requests.add(request);
              final offset = int.parse(request.url.queryParameters['offset']!);
              offsets.add(offset);
              final count = offset < 4 ? 2 : 1;
              return http.Response(
                  jsonEncode({
                    'session_id': 'desktop-42',
                    'data': [
                      for (var i = offset; i < offset + count; i++)
                        {'role': 'assistant', 'content': 'Message $i'}
                    ],
                    'pagination': {
                      'limit': 2,
                      'offset': offset,
                      'returned': count,
                      'order': 'asc'
                    },
                  }),
                  200);
            })));
    final connection = <String, dynamic>{
      'id': 'h',
      'name': 'Hermes',
      'url': 'https://hermes.example',
      'type': 'hermes'
    };
    controller.connections.add(connection);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemoteHistoryPage(
            controller: controller,
            connection: connection,
            session: RemoteSession({'id': 'desktop-42', 'title': 'Remote'}))));
    final page = find.byType(RemoteHistoryPage);
    final scroll = find
        .descendant(
            of: find.descendant(of: page, matching: find.byType(ListView)),
            matching: find.byType(Scrollable))
        .first;
    await revealRemoteHistory(tester,
        sessionId: 'desktop-42', connection: connection, content: 'Message 0');
    expect(find.text('Message 0'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Load more history'), 160,
        scrollable: scroll);
    expect(find.text('Load more history'), findsOneWidget);
    await tester.tap(find.text('Load more history'));
    await revealRemoteHistory(tester,
        sessionId: 'desktop-42', connection: connection, content: 'Message 2');
    expect(find.text('Message 2'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Load more history'), 160,
        scrollable: scroll);
    await tester.tap(find.text('Load more history'));
    await revealRemoteHistory(tester,
        sessionId: 'desktop-42', connection: connection, content: 'Message 4');
    expect(find.text('Message 4'), findsOneWidget);
    expect(find.text('Load more history'), findsNothing);
    expect(offsets, [0, 2, 4]);
    expect(requests, hasLength(3));
    for (final request in requests) {
      expect(request.method, 'GET');
      expect(request.url.host, 'hermes.example');
      expect(request.url.path, '/api/sessions/desktop-42/messages');
    }
    expect(controller.connections.single, same(connection));
    expect(controller.current, isNull);
    expect(controller.sessions, isEmpty);
    for (var i = 0; i < 5; i++) {
      expect(find.text('Message $i', skipOffstage: false), findsOneWidget);
    }
  });
}
