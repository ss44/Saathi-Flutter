import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/optimizer_settings.dart';

import 'controller_http_test.dart' show makeStore;
import '../runtime_flow_test.dart' show runtimeCapabilities;

void main() {
  Future<ChatController> open(WidgetTester t, Size size,
      {double textScale = 1}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = ChatController(await makeStore());
    await c.load();
    final connection = {
      'id': 'desktop',
      'name': 'Desktop fixture',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(connection, '');
    await c.newSession(connection, 'first-model', '');
    await c.newSession(connection, 'second-model', '');
    await t.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ChatHome(controller: c),
    ));
    await t.pumpAndSettle();
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
    return c;
  }

  for (final size in [const Size(1440, 900), const Size(1024, 600)]) {
    testWidgets('wide shell exposes chats beside the conversation at $size',
        (t) async {
      final c = await open(t, size);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byTooltip('Open navigation menu'), findsNothing);
      expect(find.byTooltip('Connection settings'), findsNothing);
      final search = find.byKey(const Key('local-history-search'));
      final composer = find.byKey(const Key('composer'));
      expect(search.hitTestable(), findsOneWidget);
      expect(t.getRect(search).right, lessThan(t.getRect(composer).left));
      await t.enterText(composer, 'Owned by the second conversation');
      await t.tap(find.text('On this device · first-model'));
      await t.pumpAndSettle();
      expect(c.current, same(c.sessions.first));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(t.widget<TextField>(composer).controller!.text, isEmpty);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('settings stays inside shell and retains the current draft',
      (t) async {
    final c = await open(t, const Size(1440, 900));
    final session = c.current;
    final composer = find.byKey(const Key('composer'));
    await t.enterText(composer, 'Keep this unsent draft');
    await t.tap(find.text('Settings'));
    await t.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Connections'), findsOneWidget);
    await t.tap(find.text('Chats'));
    await t.pumpAndSettle();
    expect(c.current, same(session));
    expect(t.widget<TextField>(composer).controller!.text,
        'Keep this unsent draft');
    expect(t.takeException(), isNull);
  });

  testWidgets('desktop Settings Back returns to chat after detail navigation',
      (t) async {
    final c = await open(t, const Size(1440, 900));
    final session = c.current;
    final composer = find.byKey(const Key('composer'));
    await t.enterText(composer, 'Keep draft across settings Back');
    await t.tap(find.text('Settings'));
    await t.pumpAndSettle();
    await t.tap(find.text('Add connection'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('Connections'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(composer.hitTestable(), findsOneWidget);
    expect(c.current, same(session));
    expect(t.widget<TextField>(composer).controller!.text,
        'Keep draft across settings Back');
    expect(t.takeException(), isNull);
  });

  testWidgets('desktop Settings scopes overrides on each deliberate entry',
      (t) async {
    final c = await open(t, const Size(1440, 900));
    const firstOverride =
        OptimizerSelection(connectionId: 'desktop', model: 'first-rewrite');
    const secondOverride =
        OptimizerSelection(connectionId: 'desktop', model: 'second-rewrite');
    await c.saveOptimizerSelection(firstOverride, chat: c.sessions.first);
    await c.saveOptimizerSelection(secondOverride, chat: c.sessions.last);
    await t.tap(find.text('On this device · first-model'));
    await t.pumpAndSettle();
    expect(find.byTooltip('Chat prompt optimizer'), findsNothing);
    expect(find.byTooltip('Settings'), findsNothing);
    for (final model in ['first-rewrite', 'second-rewrite']) {
      await t.tap(find.descendant(
          of: find.byType(NavigationRail), matching: find.text('Settings')));
      await t.pumpAndSettle();
      expect(find.text('Current conversation'), findsOneWidget);
      final override = find.widgetWithText(ListTile, 'Chat prompt optimizer');
      await t.ensureVisible(override);
      await t.tap(override);
      await t.pumpAndSettle();
      expect(find.text('Selected: Desktop fixture · $model'), findsOneWidget);
      await t.tap(find.text('Inherit global setting'));
      await t.pumpAndSettle();
      expect(c.optimizerOverride(c.current!), isNull);
      expect(c.globalOptimizerSelection, isNull);
      await t.tap(find.text('Chats'));
      await t.pumpAndSettle();
      await t.tap(find.text('On this device · second-model'));
      await t.pumpAndSettle();
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('resizing preserves draft and restores compact navigation',
      (t) async {
    await open(t, const Size(1440, 900));
    final composer = find.byKey(const Key('composer'));
    await t.enterText(composer, 'Resize without sending');
    final editable = t.state<EditableTextState>(
        find.descendant(of: composer, matching: find.byType(EditableText)));
    expect(editable.widget.focusNode.hasFocus, isTrue);
    t.view.physicalSize = const Size(390, 844);
    await t.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    expect(t.widget<TextField>(composer).controller!.text,
        'Resize without sending');
    expect(editable.mounted, isTrue);
    expect(editable.widget.focusNode.hasFocus, isTrue);
    t.view.physicalSize = const Size(1440, 900);
    await t.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(t.widget<TextField>(composer).controller!.text,
        'Resize without sending');
    expect(t.takeException(), isNull);
  });

  testWidgets('selected sidebar row returns from settings without losing draft',
      (t) async {
    await open(t, const Size(1440, 900));
    final composer = find.byKey(const Key('composer'));
    await t.enterText(composer, 'Still belongs to this conversation');
    await t.tap(find.text('Settings'));
    await t.pumpAndSettle();
    await t.tap(find.text('On this device · second-model'));
    await t.pumpAndSettle();
    expect(composer.hitTestable(), findsOneWidget);
    expect(t.widget<TextField>(composer).controller!.text,
        'Still belongs to this conversation');
  });

  testWidgets('remote continuation from settings returns to visible chat',
      (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
          jsonEncode(switch (request.url.path) {
            '/v1/capabilities' => runtimeCapabilities,
            '/api/sessions' => {
                'data': [
                  {
                    'id': 'external',
                    'title': 'Remote fixture',
                    'source': 'api_server',
                    'model': 'original'
                  }
                ],
                'has_more': false,
              },
            _ => {
                'session_id': 'external',
                'data': [
                  {'role': 'assistant', 'content': 'Existing remote answer'}
                ],
                'pagination': {'has_more': false},
              },
          }),
          200);
    });
    final c = ChatController(await makeStore(),
        coreFactory: () => SaathiCore(client: client),
        runClientFactory: (root, key) => RunClient(root, key, client: client));
    await c.load();
    await c.addConnection({
      'id': 'hermes',
      'name': 'Fixture Hermes',
      'type': 'hermes',
      'url': 'https://example.com',
    }, 'fixture');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    Future<void> network() async {
      for (var i = 0; i < 6; i++) {
        await t.pump();
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
      }
      await t.pumpAndSettle();
    }

    await network();
    await t.tap(find.text('Settings'));
    await network();
    expect(find.text('Remote fixture'), findsOneWidget,
        reason: 'requests=${requests.map((r) => r.url)}');
    await t.tap(find.text('Remote fixture'));
    await network();
    await t.tap(find.text('Continue conversation'));
    await network();
    expect(c.current?.remoteSessionId, 'external');
    expect(find.byKey(const Key('composer')).hitTestable(), findsOneWidget);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('large text uses compact layout when panes would be cramped',
      (t) async {
    await open(t, const Size(1024, 768), textScale: 2);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    expect(find.byTooltip('Send').hitTestable(), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
