import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/prompt_optimizer.dart';

class DelayedSecrets extends MemorySecrets {
  final pending = Completer<String?>();
  @override
  Future<String?> read(String id) => pending.future;
}

String response(String text) => jsonEncode({
      'choices': [
        {
          'message': {'content': text}
        }
      ]
    });

Future<ChatController> controller(SecretStore secrets,
    Future<http.Response> Function(http.Request) handler) async {
  SharedPreferences.setMockInitialValues({});
  final c = ChatController(
      SaathiStore(
          preferences: await SharedPreferences.getInstance(), secrets: secrets),
      coreFactory: () => SaathiCore(client: MockClient(handler)));
  c.loading = false;
  c.connections.add({
    'id': 'direct',
    'name': 'Direct',
    'type': 'openai',
    'url': 'http://localhost:9999',
    'model': 'test'
  });
  c.current = ChatSession(
      id: 's',
      connectionId: 'direct',
      model: 'test',
      systemPrompt: 'PRIVATE SYSTEM',
      messages: [ChatMessage(role: 'user', content: 'PRIVATE HISTORY')]);
  return c;
}

Future<void> open(
    WidgetTester tester, ChatController c, TextEditingController draft,
    {double scale = 1, double keyboard = 0}) async {
  await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: child!),
      home: Scaffold(body: PromptOptimizer(controller: c, composer: draft))));
  await tester.tap(find.byTooltip('Improve prompt'));
  await tester.pumpAndSettle();
}

Future<void> improve(WidgetTester tester) async {
  await tester.tap(find.text('Improve'));
  await tester.pump();
}

Future<void> flush(WidgetTester tester) async {
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await tester.pumpAndSettle();
}

Future<void> cleanup(
    WidgetTester tester, ChatController c, TextEditingController draft,
    {bool disposed = false}) async {
  await tester.pumpWidget(const SizedBox());
  draft.dispose();
  if (!disposed) c.dispose();
}

void main() {
  testWidgets('newer draft while HTTP pending cannot be overwritten by Apply',
      (tester) async {
    final pending = Completer<http.Response>();
    final c = await controller(MemorySecrets(), (_) => pending.future);
    final draft = TextEditingController(text: 'Original');
    await open(tester, c, draft);
    await improve(tester);
    draft.text = 'Newer draft';
    pending.complete(http.Response(response('Improved'), 200));
    await flush(tester);
    expect(find.text('Apply'), findsNothing);
    expect(draft.text, 'Newer draft');
    expect(find.text('Undo'), findsNothing);
    await cleanup(tester, c, draft);
  });
  for (final phase in ['secure read', 'HTTP']) {
    for (final change in ['draft', 'session', 'owner only']) {
      testWidgets('$change during $phase revokes mounted dialog request',
          (tester) async {
        final secrets = DelayedSecrets();
        final pending = Completer<http.Response>();
        var requests = 0;
        final c = await controller(secrets, (_) {
          requests++;
          return pending.future;
        });
        final draft = TextEditingController(text: 'Original');
        final ownerVisible = ValueNotifier(true);
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: ownerVisible,
            builder: (context, visible, child) => visible
                ? PromptOptimizer(controller: c, composer: draft)
                : const SizedBox(),
          ),
        )));
        await tester.tap(find.byTooltip('Improve prompt'));
        await tester.pumpAndSettle();
        await improve(tester);
        if (phase == 'HTTP') {
          secrets.pending.complete('synthetic');
          await tester.pump();
          expect(requests, 1);
        }
        if (change == 'draft') {
          draft.text = 'Newer draft';
        } else if (change == 'session') {
          c.current =
              ChatSession(id: 'new', connectionId: 'direct', model: 'test');
          c.notifyListeners();
        } else {
          ownerVisible.value = false;
        }
        await tester.pump();
        expect(find.byType(AlertDialog), findsOneWidget);
        if (change == 'owner only') {
          expect(find.byType(PromptOptimizer), findsNothing);
          expect(find.byType(Navigator), findsOneWidget);
        }
        if (phase == 'secure read') secrets.pending.complete('synthetic');
        pending.complete(http.Response(response('Improved'), 200));
        await flush(tester);
        expect(requests, phase == 'secure read' ? 0 : 1);
        expect(find.text('Apply'), findsNothing);
        expect(draft.text, change == 'draft' ? 'Newer draft' : 'Original');
        await cleanup(tester, c, draft);
        ownerVisible.dispose();
      });
    }
  }
  testWidgets('Undo disappears after manual edit', (tester) async {
    final c = await controller(
        MemorySecrets(), (_) async => http.Response(response('Improved'), 200));
    final draft = TextEditingController(text: 'Original');
    await open(tester, c, draft);
    await improve(tester);
    await flush(tester);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);
    draft.text = 'Manual edit';
    await tester.pump();
    expect(find.text('Undo'), findsNothing);
    expect(draft.text, 'Manual edit');
    await cleanup(tester, c, draft);
  });
  for (final action in [
    'cancel',
    'owner dispose',
    'map replacement',
    'key rotation'
  ]) {
    testWidgets('$action during secure read prevents late HTTP and Apply',
        (tester) async {
      final secrets = DelayedSecrets();
      var requests = 0;
      final c = await controller(secrets, (_) async {
        requests++;
        return http.Response(response('Improved'), 200);
      });
      final draft = TextEditingController(text: 'Original');
      await open(tester, c, draft);
      await improve(tester);
      if (action == 'cancel') {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      } else if (action == 'owner dispose') {
        await tester.pumpWidget(const SizedBox());
      } else {
        if (action == 'key rotation') await secrets.write('direct', 'rotated');
        c.connections[0] = {...c.connections[0]};
        c.notifyListeners();
        await tester.pump();
      }
      secrets.pending.complete('old key');
      await flush(tester);
      expect(requests, 0);
      expect(find.text('Apply'), findsNothing);
      expect(draft.text, 'Original');
      await cleanup(tester, c, draft);
    });
  }
  for (final failure in ['secure read', 'transport', 'empty response']) {
    testWidgets('$failure failure leaves original untouched', (tester) async {
      final secrets = DelayedSecrets();
      var requests = 0;
      final c = await controller(secrets, (_) async {
        requests++;
        if (failure == 'transport') throw http.ClientException('offline');
        return http.Response(response(''), 200);
      });
      final draft = TextEditingController(text: 'Original');
      await open(tester, c, draft);
      await improve(tester);
      if (failure == 'secure read') {
        secrets.pending.completeError(StateError('locked'));
      } else {
        secrets.pending.complete('key');
      }
      await flush(tester);
      expect(requests, failure == 'secure read' ? 0 : 1);
      expect(find.textContaining('Could not improve'), findsOneWidget);
      expect(find.text('Apply'), findsNothing);
      expect(draft.text, 'Original');
      await cleanup(tester, c, draft);
    });
  }
  testWidgets(
      'Hermes requires explicit direct destination before any API request',
      (tester) async {
    var requests = 0;
    final c = await controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response(response('Improved'), 200);
    });
    final direct = c.connections.removeAt(0);
    c.connections.add({'id': 'agent', 'name': 'Hermes', 'type': 'hermes'});
    c.current =
        ChatSession(id: 'agent-chat', connectionId: 'agent', model: 'agent');
    final draft = TextEditingController(text: 'Original');
    await open(tester, c, draft);
    expect(find.textContaining('No direct text'), findsOneWidget);
    expect(requests, 0);
    c.connections.add(direct);
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Improve'))
            .onPressed,
        isNull);
    expect(requests, 0);
    await tester
        .tap(find.byType(DropdownButtonFormField<Map<String, dynamic>>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct').last);
    await tester.pumpAndSettle();
    expect(requests, 0);
    await improve(tester);
    await flush(tester);
    expect(requests, 1);
    expect(c.current!.connectionId, 'agent');
    expect(draft.text, 'Original');
    await cleanup(tester, c, draft);
  });
  for (final type in [
    ProviderType.openai,
    ProviderType.anthropic,
    ProviderType.gemini
  ]) {
    test(
        '${type.name} wire contains only rewrite system and draft, no history or tools',
        () async {
      final requests = <http.Request>[];
      final core = SaathiCore(client: MockClient((r) async {
        requests.add(r);
        return http.Response(
            jsonEncode(type == ProviderType.anthropic
                ? {
                    'content': [
                      {'type': 'text', 'text': 'Improved'}
                    ]
                  }
                : type == ProviderType.gemini
                    ? {
                        'candidates': [
                          {
                            'content': {
                              'parts': [
                                {'text': 'Improved'}
                              ]
                            }
                          }
                        ]
                      }
                    : jsonDecode(response('Improved'))),
            200);
      }));
      core.restoreHistory(
          [ChatMessage(role: 'user', content: 'PRIVATE HISTORY')]);
      core.setSystemPrompt('PRIVATE SYSTEM');
      expect(
          await rewritePrompt(
              core,
              ProviderConfig(
                  id: 'chosen',
                  name: 'Chosen',
                  type: type,
                  useGrounding: true,
                  baseUrl: 'http://localhost:9999'),
              'test-model',
              'Original'),
          'Improved');
      expect(requests, hasLength(1));
      final body = jsonDecode(requests.single.body) as Map;
      expect(body.containsKey('tools'), false);
      expect(requests.single.body, isNot(contains('PRIVATE')));
      if (type == ProviderType.openai) {
        expect((body['messages'] as List).map((m) => m['role']).toList(),
            ['system', 'user']);
        expect(body['messages'][1]['content'], 'Original');
        expect(
            body['messages'][0]['content'], contains('Rewrite the user draft'));
      } else if (type == ProviderType.anthropic) {
        expect(body['messages'], [
          {'role': 'user', 'content': 'Original'}
        ]);
        expect(body['system'], contains('Rewrite the user draft'));
      } else {
        expect(body['contents'], [
          {
            'role': 'user',
            'parts': [
              {'text': 'Original'}
            ]
          }
        ]);
        expect(body['system_instruction']['parts'][0]['text'],
            contains('Rewrite the user draft'));
      }
      expect(core.history, isEmpty);
      core.close();
    });
  }
  for (final width in [390.0, 360.0]) {
    testWidgets(
        '${width.toInt()} long Original and Improved with keyboard keeps actions reachable',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final text = List.filled(80, 'Long original draft line.').join('\n');
      final better = List.filled(80, 'Long improved draft line.').join('\n');
      final c = await controller(
          MemorySecrets(), (_) async => http.Response(response(better), 200));
      final draft = TextEditingController(text: text);
      await open(tester, c, draft, scale: width == 360 ? 2 : 1, keyboard: 280);
      await tester.ensureVisible(find.text('Improve'));
      await improve(tester);
      await flush(tester);
      expect(find.text('Original'), findsOneWidget);
      expect(find.text('Improved'), findsOneWidget);
      await tester.drag(
          find.byType(SingleChildScrollView).first, const Offset(0, -1800));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Apply'));
      expect(find.text('Apply').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('Keep original'));
      expect(find.text('Keep original').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Keep original'));
      await tester.pumpAndSettle();
      expect(draft.text, text);
      await cleanup(tester, c, draft);
    });
  }
  for (final action in [
    'controller dispose',
    'map replacement',
    'key rotation'
  ]) {
    testWidgets('$action during HTTP rejects late preview', (tester) async {
      final pending = Completer<http.Response>();
      var requests = 0;
      final secrets = MemorySecrets();
      final c = await controller(secrets, (_) {
        requests++;
        return pending.future;
      });
      final draft = TextEditingController(text: 'Original');
      await open(tester, c, draft);
      await improve(tester);
      await tester.pump();
      expect(requests, 1);
      if (action == 'controller dispose') {
        c.dispose();
      } else {
        if (action == 'key rotation') await secrets.write('direct', 'rotated');
        c.connections[0] = {...c.connections[0]};
        c.notifyListeners();
      }
      pending.complete(http.Response(response('Improved'), 200));
      await flush(tester);
      expect(requests, 1);
      expect(find.text('Apply'), findsNothing);
      expect(draft.text, 'Original');
      await cleanup(tester, c, draft, disposed: action == 'controller dispose');
    });
  }
  testWidgets('disposed source during secure read never starts HTTP',
      (tester) async {
    final secrets = DelayedSecrets();
    var requests = 0;
    final c = await controller(secrets, (_) async {
      requests++;
      return http.Response(response('Improved'), 200);
    });
    final draft = TextEditingController(text: 'Original');
    await open(tester, c, draft);
    await improve(tester);
    c.dispose();
    secrets.pending.complete('key');
    await flush(tester);
    expect(requests, 0);
    expect(find.text('Apply'), findsNothing);
    expect(draft.text, 'Original');
    await cleanup(tester, c, draft, disposed: true);
  });
}
