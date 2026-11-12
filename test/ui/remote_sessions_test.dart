import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
  testWidgets(
      'remote sessions show server-owned history read-only without replay',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    await store.saveConnection({
      'id': 'h',
      'name': 'My Hermes',
      'url': 'https://hermes.example',
      'type': 'hermes'
    }, apiKey: 'test');
    final requests = <http.Request>[];
    final client = MockClient((r) async {
      requests.add(r);
      if (r.url.path == '/v1/capabilities') return http.Response('{}', 200);
      if (r.url.path == '/api/sessions') {
        return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'desktop-42',
                  'title': 'Open desktop chat',
                  'source': 'desktop'
                }
              ],
              'has_more': false
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'session_id': 'desktop-42',
            'data': [
              {
                'role': 'assistant',
                'content': 'Visible answer',
                'reasoning_content': 'PRIVATE REASONING'
              },
              {'role': 'tool', 'content': 'PRIVATE TOOL DATA'}
            ],
            'pagination': {'has_more': false}
          }),
          200);
    });
    await tester.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Connection settings'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Browse remote sessions'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Open desktop chat'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Read-only'), findsWidgets);
    expect(find.text('Visible answer'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.byKey(const Key('composer')), findsNothing);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    expect((await store.load()).chats, isEmpty);
  });
}
