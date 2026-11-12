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

void main() {
  testWidgets('source history envelope without has_more reaches newer messages',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final offsets = <int>[];
    final controller = ChatController(store,
        coreFactory: () => SaathiCore(client: MockClient((request) async {
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
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RemoteHistoryPage(
            controller: controller,
            connection: const {
              'id': 'h',
              'name': 'Hermes',
              'url': 'https://hermes.example',
              'type': 'hermes'
            },
            session: RemoteSession({'id': 'desktop-42', 'title': 'Remote'}))));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Message 0'), findsOneWidget);
    expect(find.text('Load more history'), findsOneWidget);
    await tester.tap(find.text('Load more history'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Message 2'), findsOneWidget);
    await tester.ensureVisible(find.text('Load more history'));
    await tester.tap(find.text('Load more history'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Message 4'), findsOneWidget);
    expect(find.text('Load more history'), findsNothing);
    expect(offsets, [0, 2, 4]);
    for (var i = 0; i < 5; i++) {
      expect(find.text('Message $i', skipOffstage: false), findsOneWidget);
    }
  });
}
