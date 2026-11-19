import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'optimizer_persistence_test.dart' show PreferenceDisk;
import 'prompt_optimizer_acceptance_test.dart' as fixture;
import 'optimizer_settings_driver.dart';

Future<void> until(WidgetTester tester, bool Function() settled) async {
  for (var i = 0; i < 30 && !settled(); i++) {
    await fixture.flush(tester);
  }
  expect(settled(), isTrue,
      reason: 'Await the actual asynchronous UI boundary');
}

bool improveEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Improve'))
        .onPressed !=
    null;

void main() {
  for (final mutation in ['replace', 'remove']) {
    testWidgets(
        '$mutation optimizer source explains revocation without switching to reply source',
        (tester) async {
      final requests = <http.Request>[];
      final c = await fixture.controller(MemorySecrets(), (r) async {
        requests.add(r);
        return http.Response(
            jsonEncode({
              'data': [
                {'id': 'test'}
              ]
            }),
            200);
      }, catalogFixture: false);
      c.connections.add({
        'id': 'optimizer',
        'name': 'Optimizer only',
        'type': 'openai',
        'url': 'http://localhost:9998'
      });
      await c.saveOptimizerSelection(
          const OptimizerSelection(connectionId: 'optimizer', model: 'test'));
      final draft = TextEditingController(text: 'Private draft');
      await fixture.open(tester, c, draft);
      await until(tester, () => improveEnabled(tester));
      expect(requests.single.url.port, 9998);
      if (mutation == 'replace') {
        c.connections[1] = {...c.connections[1]};
      } else {
        c.connections.removeLast();
      }
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Selected connection changed or was removed. Choose an explicit replacement.'),
          findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Improve'))
              .onPressed,
          isNull);
      expect(requests, hasLength(1));
      expect(c.globalOptimizerSelection!.connectionId, 'optimizer');
      expect(draft.text, 'Private draft');
      await fixture.cleanup(tester, c, draft);
    });
  }

  for (final type in ['hermes', 'hermesGateway', 'openclaw']) {
    testWidgets(
        '$type persisted destination stays explicit and never uses a direct fallback',
        (tester) async {
      var requests = 0;
      final c = await fixture.controller(MemorySecrets(), (_) async {
        requests++;
        return http.Response('{}', 200);
      }, catalogFixture: false);
      c.connections.add({'id': 'native', 'name': 'Native', 'type': type});
      await c.saveOptimizerSelection(const OptimizerSelection(
          connectionId: 'native', model: 'native-model'));
      final draft = TextEditingController(text: 'Private draft');
      await fixture.open(tester, c, draft);
      expect(
          find.textContaining(
              'Selected destination unavailable for a bounded text-only rewrite'),
          findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Improve'))
              .onPressed,
          isNull);
      expect(requests, 0);
      expect(c.globalOptimizerSelection!.connectionId, 'native');
      await fixture.cleanup(tester, c, draft);
    });
  }

  testWidgets(
      'real settings controls survive cold reload and route only consented draft to the override, then inherited global',
      (tester) async {
    final disk = PreferenceDisk()..install();
    addTearDown(disk.dispose);
    final secrets = MemorySecrets();
    final requests = <http.Request>[];
    SaathiCore core() => SaathiCore(client: MockClient((r) async {
          requests.add(r);
          if (r.method == 'GET') {
            return http.Response(
                jsonEncode({
                  'data': [
                    {
                      'id':
                          r.url.port == 9998 ? 'override-model' : 'global-model'
                    }
                  ]
                }),
                200);
          }
          return http.Response(fixture.response('Improved draft'), 200);
        }));
    Future<ChatController> load() async {
      final c = ChatController(
          SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: secrets),
          coreFactory: core);
      await c.load();
      return c;
    }

    var c = await load();
    for (final port in [9999, 9998]) {
      await c.addConnection({
        'id': 'connection-$port',
        'name': port == 9999 ? 'Global source' : 'Override source',
        'type': 'openai',
        'url': 'http://localhost:$port'
      }, 'fixture-$port');
    }
    await c.newSession(c.connections.first, 'reply-only', 'PRIVATE SYSTEM');
    c.current!.messages
        .add(ChatMessage(role: 'user', content: 'PRIVATE HISTORY'));
    await c.store.saveChats(c.sessions.map((chat) => chat.toJson()).toList());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: ConnectionsPage(controller: c)));
    await openOptimizerSettings(tester);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Global source')));
    await fixture.flush(tester);
    await tester.tap(find.text('global-model'));
    await tester.pumpAndSettle();
    expect(c.globalOptimizerSelection!.model, 'global-model');
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.pumpAndSettle();
    await openOptimizerSettings(tester, chat: true);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Override source')));
    await fixture.flush(tester);
    await tester.tap(find.text('override-model'));
    await tester.pumpAndSettle();
    expect(c.optimizerOverride(c.current!)!.model, 'override-model');
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    expect(c.current!.model, 'reply-only');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    SharedPreferences.resetStatic();
    c = await load();
    expect(c.optimizerOverride(c.current!)!.model, 'override-model');
    expect(c.current!.messages.single.content, 'PRIVATE HISTORY');
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    final composer = find.byKey(const Key('composer'));
    await tester.enterText(composer, 'Only this draft');
    await tester.pumpAndSettle();
    for (final inherited in [false, true]) {
      if (inherited) {
        await openOptimizerSettings(tester, chat: true);
        await tester.tap(find.text('Inherit global setting'));
        await tester.pumpAndSettle();
        await returnFromSettings(tester);
      }
      final postsBefore = requests.where((r) => r.method == 'POST').length;
      await tester.longPress(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Enhance prompt'));
      await fixture.flush(tester);
      expect(
          find.text(
              inherited ? 'Inheriting global setting' : 'Using chat override'),
          findsOneWidget);
      expect(
          find.textContaining(inherited
              ? 'Destination: Global source'
              : 'Destination: Override source'),
          findsOneWidget);
      await until(tester, () => improveEnabled(tester));
      expect(requests.where((r) => r.method == 'POST').length, postsBefore);
      await tester.tap(find.text('Improve'));
      await until(tester, () => find.text('Apply').evaluate().isNotEmpty);
      final posts = requests.where((r) => r.method == 'POST').toList();
      expect(posts.length, postsBefore + 1);
      final post = posts.last;
      expect(post.url.port, inherited ? 9999 : 9998);
      expect(post.headers['authorization'],
          'Bearer fixture-${inherited ? 9999 : 9998}');
      expect(post.body, isNot(contains('PRIVATE')));
      final body = jsonDecode(post.body) as Map;
      expect(body['model'], inherited ? 'global-model' : 'override-model');
      expect(body['messages'], hasLength(2));
      expect(body['messages'][1]['content'], 'Only this draft');
      expect(body.containsKey('tools'), isFalse);
      if (inherited) {
        await tester.tap(find.text('Keep original'));
      } else {
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(composer).controller!.text,
            'Improved draft');
        await tester.tap(find.text('Undo'));
      }
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller!.text,
          'Only this draft');
      expect(c.current!.messages.single.content, 'PRIVATE HISTORY');
      expect(c.current!.model, 'reply-only');
    }
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    SharedPreferences.resetStatic();
    c = await load();
    expect(c.optimizerOverride(c.current!), isNull);
    expect(c.optimizerSelection(c.current)!.model, 'global-model');
    c.dispose();
  });
}
