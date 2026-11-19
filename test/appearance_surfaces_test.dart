import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SaathiStore> appearanceChatStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets());
  await store.saveConnection({
    'id': 'local',
    'name': 'Fixture',
    'type': 'openai',
    'url': 'https://example.test',
  }, apiKey: 'fixture-only');
  await store.saveChats([
    {
      'id': 'chat',
      'connectionId': 'local',
      'model': 'fixture',
      'messages': [
        {'role': 'user', 'content': 'Historical question'},
        {
          'role': 'assistant',
          'content':
              'An answer with `inline code`.\n\n```dart\nprint(1);\n```\n\n![blocked](https://example.test/private.png)'
        },
      ],
    }
  ]);
  return store;
}

void main() {
  testWidgets('remote historical Markdown follows the same live palette',
      (tester) async {
    final store = await appearanceChatStore();
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      return http.Response(
          jsonEncode({
            'session_id': 'remote',
            'data': [
              {
                'role': 'assistant',
                'content':
                    '[link](https://example.test) and `code`\n\n```\nblock\n```'
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
            session: RemoteSession({'id': 'remote', 'title': 'Remote'})))));
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      final scheme =
          Theme.of(tester.element(find.byType(MarkdownBody))).colorScheme;
      expect(markdown.styleSheet?.a?.color, scheme.primary);
      expect(markdown.styleSheet?.code?.color, scheme.onSurface);
      expect(markdown.styleSheet?.code?.backgroundColor,
          scheme.surfaceContainerHighest);
    }
  });
  testWidgets('historical bubbles composer and Markdown use paired theme roles',
      (tester) async {
    final store = await appearanceChatStore();
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(SaathiApp(store: store));
    await tester.pumpAndSettle();
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      final scheme =
          Theme.of(tester.element(find.byType(ChatHome))).colorScheme;
      final composerContainer = tester
          .widgetList<Container>(find.ancestor(
              of: find.byKey(const Key('composer')),
              matching: find.byType(Container)))
          .firstWhere((widget) => widget.decoration is BoxDecoration);
      expect((composerContainer.decoration! as BoxDecoration).color,
          scheme.surfaceContainerLow);
      final user = find
          .byWidgetPredicate((widget) => widget is MessageView && widget.user);
      final bubble = tester
          .widgetList<Container>(
              find.descendant(of: user, matching: find.byType(Container)))
          .firstWhere((widget) => widget.decoration is BoxDecoration);
      expect((bubble.decoration! as BoxDecoration).color,
          scheme.secondaryContainer);
      expect(
          tester
              .widget<Text>(find.descendant(
                  of: user, matching: find.text('Historical question')))
              .style!
              .color,
          scheme.onSecondaryContainer);
      final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(markdown.styleSheet!.a?.color, scheme.primary);
      expect(markdown.styleSheet!.code!.color, scheme.onSurface);
      expect(markdown.styleSheet!.code!.backgroundColor,
          scheme.surfaceContainerHighest);
      expect((markdown.styleSheet!.codeblockDecoration! as BoxDecoration).color,
          scheme.surfaceContainerHighest);
      expect(find.text('[Image blocked: automatic loading is disabled]'),
          findsOneWidget);
      for (final pair in [
        (scheme.onSurface, scheme.surfaceContainerLow),
        (scheme.onSurfaceVariant, scheme.surface),
        (scheme.onSecondaryContainer, scheme.secondaryContainer),
        (scheme.onSurface, scheme.surfaceContainerHighest),
        (scheme.error, scheme.surface),
        (scheme.primary, scheme.surface),
      ]) {
        final a = pair.$1.computeLuminance();
        final b = pair.$2.computeLuminance();
        expect(((a > b ? a : b) + 0.05) / ((a > b ? b : a) + 0.05),
            greaterThanOrEqualTo(4.5));
      }
      expect(tester.takeException(), isNull);
    }
  });
}
