import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ChatController> _makeController({
  http.Client? client,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = SaathiStore(
    preferences: await SharedPreferences.getInstance(),
    secrets: MemorySecrets(),
  );
  final c = ChatController(
    store,
    coreFactory: client == null ? null : () => SaathiCore(client: client),
  );
  await c.load();
  return c;
}

void main() {
  testWidgets(
      'empty state Connect a model opens AddConnectionPage directly with default URLs and hides OpenClaw',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/models') {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'gpt-4o-mini'},
            ]
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final c = await _makeController(client: client);
    addTearDown(c.dispose);

    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect a model'));
    await tester.pumpAndSettle();

    // Direct to AddConnectionPage without routing through global Settings.
    expect(find.byType(AddConnectionPage), findsOneWidget);
    expect(find.byType(ConnectionsPage), findsNothing);

    // Default OpenAI base URL is pre-filled.
    final urlField = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, 'API base URL'),
    );
    expect(urlField.controller!.text, 'https://api.openai.com');

    // OpenClaw is excluded from new-connection provider choices; switching updates default URL.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('OpenClaw'), findsNothing);
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();
    expect(urlField.controller!.text, 'https://api.anthropic.com');

    // Switch back to OpenAI-compatible and test connection without saving.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI-compatible').last);
    await tester.pumpAndSettle();
    expect(urlField.controller!.text, 'https://api.openai.com');

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Connection name'),
      'Primary',
    );
    await tester.scrollUntilVisible(
      find.text('Test connection'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(AddConnectionPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Test connection'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Connection verified'), findsOneWidget);
    expect(c.connections, isEmpty);

    await tester.scrollUntilVisible(
      find.text('Save connection'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(AddConnectionPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Save connection'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();

    // Automatically advances into NewChatPage and auto-discovers models.
    expect(find.byType(NewChatPage), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Available models'), findsOneWidget);
    expect(
        find.textContaining('Live attachment is not available'), findsNothing);
    expect(
      find.textContaining('Start a new conversation to change them'),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'NewChatPage remembers last-used connection/model and attaches selected persona',
      (tester) async {
    final c = await _makeController();
    addTearDown(c.dispose);
    await c.addConnection({
      'id': 'first',
      'name': 'First',
      'type': 'openai',
      'url': 'https://first.example',
    }, '');
    await c.addConnection({
      'id': 'second',
      'name': 'Second',
      'type': 'anthropic',
      'url': 'https://second.example',
    }, '');
    await c.organization.savePersona(
      const SharedPersona(
        id: 'p1',
        name: 'Reviewer',
        instructions: 'Be concise and thorough.',
      ),
      canEdit: (_) => null,
    );
    await c.newSession(c.connections.last, 'claude-sonnet', '');

    await tester.pumpWidget(MaterialApp(home: NewChatPage(controller: c)));
    await tester.pumpAndSettle();

    // Preselects last-used connection ('Second') and model ('claude-sonnet').
    expect(find.text('Second'), findsOneWidget);
    final modelField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Model ID'),
    );
    expect(modelField.controller!.text, 'claude-sonnet');

    // Allows choosing an existing shared persona.
    await tester.scrollUntilVisible(
      find.byKey(const Key('new-chat-persona')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('new-chat-persona')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reviewer').last);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Start conversation'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Start conversation'));
    await tester.pumpAndSettle();

    expect(c.sessions, hasLength(2));
    expect(c.current!.connectionId, 'second');
    expect(c.current!.model, 'claude-sonnet');
    expect(c.organization.entry(c.identityOf(c.current!)).personaId, 'p1');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'onboarding forms remain usable at 360px with 2x text and keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    final c = await _makeController();
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: AddConnectionPage(controller: c),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
