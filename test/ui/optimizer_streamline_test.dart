import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/prompt_optimizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'PromptReview uses Enhance naming and skips duplicate catalog fetch right after choosing a model',
      (tester) async {
    var modelGets = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/v1/models') {
        modelGets++;
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'fast-model'},
            ]
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Enhanced draft'}
            }
          ]
        }),
        200,
      );
    });
    addTearDown(client.close);
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets(),
    );
    final c = ChatController(
      store,
      coreFactory: () => SaathiCore(client: client),
    );
    await c.load();
    await c.addConnection({
      'id': 'direct',
      'name': 'Direct',
      'type': 'openai',
      'url': 'https://example.test',
    }, 'fixture');
    await c.newSession(c.connections.single, 'chat-model', '');
    addTearDown(c.dispose);

    final draft = TextEditingController(text: 'Draft to polish');
    addTearDown(draft.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PromptOptimizer(controller: c, composer: draft)),
    ));

    await tester.tap(find.byTooltip('Enhance prompt'));
    await tester.pumpAndSettle();

    expect(find.text('Enhance prompt'), findsOneWidget);
    await tester.tap(find.text('Choose optimizer'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Direct'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(modelGets, 1);

    await tester.tap(find.text('fast-model'));
    await tester.pumpAndSettle();

    // Returning from OptimizerSettingsDialog should NOT trigger a second GET /v1/models.
    expect(modelGets, 1);
    final enhanceBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Enhance'),
    );
    expect(enhanceBtn.onPressed, isNotNull);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Enhance'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(find.text('Enhanced'), findsOneWidget);
    expect(find.text('Enhanced draft'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Hermes-only setup offers direct Add connection action in Enhance prompt dialog',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets(),
    );
    final c = ChatController(store);
    await c.load();
    await c.addConnection({
      'id': 'h',
      'name': 'Hermes',
      'type': 'hermes',
      'url': 'http://127.0.0.1:8642',
    }, '');
    await c.newSession(c.connections.single, 'hermes-model', '');
    addTearDown(c.dispose);

    final draft = TextEditingController(text: 'Draft');
    addTearDown(draft.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PromptOptimizer(controller: c, composer: draft)),
    ));

    await tester.tap(find.byTooltip('Enhance prompt'));
    await tester.pumpAndSettle();
    expect(find.text('Add direct connection'), findsOneWidget);
    await tester.tap(find.text('Add direct connection'));
    await tester.pumpAndSettle();
    expect(find.byType(AddConnectionPage), findsOneWidget);

    // Saving a direct connection returns cleanly to a fresh active Enhance prompt dialog.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Connection name'),
      'OpenAI',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API base URL'),
      'https://example.test',
    );
    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();
    expect(find.text('Enhance prompt'), findsOneWidget);
    expect(find.text('Add direct connection'), findsNothing);
    expect(find.textContaining('Draft or conversation changed'), findsNothing);
    expect(
      tester
          .widget<TextButton>(
              find.widgetWithText(TextButton, 'Choose optimizer'))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
