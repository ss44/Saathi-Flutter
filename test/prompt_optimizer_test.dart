import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/prompt_optimizer.dart';
import 'package:saathi/ui/optimizer_settings.dart';

void main() {
  testWidgets(
      'preview requires Apply, never sends, and Undo preserves later edits',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()),
        coreFactory: () => SaathiCore(
            client: MockClient((r) async => r.method == 'GET'
                ? http.Response(
                    jsonEncode({
                      'data': [
                        {'id': 'test'}
                      ]
                    }),
                    200)
                : http.Response(
                    jsonEncode({
                      'choices': [
                        {
                          'message': {'content': 'Improved'}
                        }
                      ]
                    }),
                    200))));
    c.loading = false;
    c.connections.add({
      'id': 'direct',
      'name': 'Direct',
      'type': 'openai',
      'url': 'http://localhost:9999'
    });
    c.current = ChatSession(id: 's', connectionId: 'direct', model: 'test');
    c.current!.messages
        .add(ChatMessage(role: 'user', content: 'PRIVATE HISTORY'));
    await c.saveOptimizerSelection(
        const OptimizerSelection(connectionId: 'direct', model: 'test'));
    final draft = TextEditingController(text: 'Original');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PromptOptimizer(controller: c, composer: draft))));
    await tester.tap(find.byTooltip('Improve prompt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('additional'), findsOneWidget);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Improve'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(draft.text, 'Original');
    expect(find.text('Apply'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(draft.text, 'Improved');
    expect(c.current!.messages, hasLength(1));
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(draft.text, 'Original');
    expect(c.current!.messages, hasLength(1));
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    expect(find.byTooltip('Improve prompt'), findsNothing);
    expect(find.byTooltip('Send'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    draft.dispose();
    c.dispose();
  });
  test('rewrite uses only explicit direct destination and no history or tools',
      () async {
    final requests = <http.Request>[];
    final core = SaathiCore(client: MockClient((r) async {
      requests.add(r);
      return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Improved'}
              }
            ]
          }),
          200);
    }));
    final result = await rewritePrompt(
        core,
        const ProviderConfig(
            id: 'chosen',
            name: 'Test',
            type: ProviderType.openai,
            baseUrl: 'http://localhost:9999'),
        'test-model',
        'Original');
    expect(result, 'Improved');
    expect(requests, hasLength(1));
    final body = jsonDecode(requests.single.body) as Map;
    expect(body['model'], 'test-model');
    expect(body.containsKey('tools'), false);
    expect((body['messages'] as List).length, 2);
    expect(body['messages'].last['content'], 'Original');
    expect(core.history, isEmpty);
    expect(
        () => rewritePrompt(
            core,
            const ProviderConfig(
                id: 'agent', name: 'Agent', type: ProviderType.hermes),
            'agent',
            'Draft'),
        throwsA(isA<UnsupportedError>()));
    expect(requests, hasLength(1));
  });
}
