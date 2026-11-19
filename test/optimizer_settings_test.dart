import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/ui/connections.dart';
import 'prompt_optimizer_acceptance_test.dart' as fixture;
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'unconfigured optimizer requires explicit destination, not response model',
      (tester) async {
    var requests = 0;
    final c = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response('{}', 200);
    });
    await c.saveOptimizerSelection(null);
    final draft = TextEditingController(text: 'Private draft');
    await fixture.open(tester, c, draft);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Improve'))
            .onPressed,
        isNull);
    expect(find.byType(TextField), findsNothing);
    expect(requests, 0);
    await fixture.cleanup(tester, c, draft);
  });
  testWidgets(
      'global optimizer groups verified models and never runs inference',
      (tester) async {
    final requests = <http.Request>[];
    final c = await fixture.controller(MemorySecrets(), (request) async {
      requests.add(request);
      return http.Response(
          jsonEncode({
            'data': [
              {'id': 'verified-model'}
            ]
          }),
          200);
    }, catalogFixture: false);
    await tester.pumpWidget(MaterialApp(home: ConnectionsPage(controller: c)));
    await tester.scrollUntilVisible(find.text('Global prompt optimizer'), 200);
    await tester.tap(find.text('Global prompt optimizer'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Direct')));
    await fixture.flush(tester);
    await tester.tap(find.text('verified-model'));
    await tester.pumpAndSettle();
    expect(
        c.globalOptimizerSelection,
        const OptimizerSelection(
            connectionId: 'direct', model: 'verified-model'));
    expect(requests.map((r) => r.method).toList(), ['GET']);
    expect(c.current!.model, 'test');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  test('optimizer override and inheritance persist separately from chat model',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final c = ChatController(store);
    final chat = ChatSession(
        id: 'chat', connectionId: 'response', model: 'response-model');
    const global =
        OptimizerSelection(connectionId: 'a', model: 'same', provider: 'one');
    const local =
        OptimizerSelection(connectionId: 'a', model: 'same', provider: 'two');
    await c.saveOptimizerSelection(global);
    expect(c.optimizerSelection(chat), global);
    await c.saveOptimizerSelection(local, chat: chat);
    expect(c.optimizerSelection(chat), local);
    expect(chat.model, 'response-model');
    final restarted = ChatController(store);
    expect(restarted.optimizerSelection(chat), local);
    await restarted.saveOptimizerSelection(null, chat: chat);
    expect(restarted.optimizerSelection(chat), global);
    final json =
        jsonDecode(store.preferences.getString('saathi.optimizer.v1')!) as Map;
    expect((json['global'] as Map).keys.toSet(),
        {'connectionId', 'model', 'provider'});
    expect(
        OptimizerSelection.fromJson(
                {'connectionId': 'a', 'model': 'same', 'apiKey': 'secret'})!
            .toJson()
            .containsKey('apiKey'),
        isFalse);
    c.dispose();
    restarted.dispose();
  });
}
