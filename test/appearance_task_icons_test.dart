import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tasks = '- [x] Completed item\n- [ ] Pending item';

void expectTaskContrast(
    WidgetTester tester, Finder row, Brightness brightness) {
  expect(row, findsOneWidget);
  final theme = Theme.of(tester.element(row));
  expect(theme.brightness, brightness);
  final bubble = tester
      .widgetList<Container>(
          find.descendant(of: row, matching: find.byType(Container)))
      .firstWhere((widget) => widget.decoration is BoxDecoration);
  final background = (bubble.decoration! as BoxDecoration).color!;
  for (final icon in [Icons.check_box, Icons.check_box_outline_blank]) {
    final finder = find.descendant(of: row, matching: find.byIcon(icon));
    expect(finder, findsOneWidget);
    final foreground = tester.widget<Icon>(finder).color!;
    expect(foreground, theme.colorScheme.primary);
    final a = foreground.computeLuminance();
    final b = background.computeLuminance();
    final contrast = ((a > b ? a : b) + 0.05) / ((a > b ? b : a) + 0.05);
    expect(contrast, greaterThanOrEqualTo(3.0));
  }
}

void main() {
  testWidgets(
      'remote task icons follow live theme with no inference or image fetch',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/sessions/remote/messages');
      return http.Response(
          jsonEncode({
            'session_id': 'remote',
            'data': [
              {
                'role': 'assistant',
                'content':
                    '$tasks\n\n![blocked](https://example.test/private.png)'
              }
            ],
            'pagination': {'offset': 0, 'returned': 1, 'limit': 100},
          }),
          200);
    });
    addTearDown(client.close);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await tester.pumpAndSettle();
    final home = find.byType(ChatHome);
    final controller = tester.widget<ChatHome>(home).controller;
    final connection = <String, dynamic>{
      'id': 'remote',
      'type': 'hermes',
      'name': 'Remote',
      'url': 'https://example.test'
    };
    controller.connections.add(connection);
    unawaited(Navigator.of(tester.element(home)).push(MaterialPageRoute<void>(
      builder: (_) => RemoteHistoryPage(
          controller: controller,
          connection: connection,
          session: RemoteSession({'id': 'remote', 'title': 'Remote'})),
    )));
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      expectTaskContrast(
          tester,
          find.descendant(
              of: find.byType(RemoteHistoryPage),
              matching: find.byType(MessageView)),
          brightness);
      expect(find.text('[Image blocked: automatic loading is disabled]'),
          findsOneWidget);
      expect(requests, 1);
      expect(tester.takeException(), isNull);
    }
  });

  for (final wrapped in [false, true]) {
    testWidgets(
        'task-state icons use semantic accent in both local branches wrapped=$wrapped',
        (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xff0f6b57), brightness: brightness),
              useMaterial3: true),
          home: Scaffold(
              body: MessageView(
                  text: tasks,
                  user: false,
                  answerBuilder: wrapped
                      ? (child) => Padding(
                          padding: const EdgeInsets.all(1), child: child)
                      : null)),
        ));
        await tester.pumpAndSettle();
        expectTaskContrast(tester, find.byType(MessageView), brightness);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
