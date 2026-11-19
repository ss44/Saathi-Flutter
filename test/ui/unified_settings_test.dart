import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/notifications/reply_notifications.dart';
import 'package:saathi/update_host.dart';
import 'package:saathi/updates/saathi_updates.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Secrets extends MemorySecrets {
  bool failWrite = true;
  @override
  Future<void> write(String id, String value) async {
    if (failWrite) throw StateError('Fixture secure write failure');
    await super.write(id, value);
  }
}

class _Notifications implements NotificationAdapter {
  int permissions = 0;
  @override
  bool get supported => true;
  @override
  Future<bool> requestPermission() async {
    permissions++;
    return true;
  }

  @override
  Future<void> show(String id) async {}
  @override
  Future<String?> consumePendingTap() async => null;
}

void main() {
  testWidgets('rewrite preferences do not alter or resend an active response',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final reply = Completer<http.Response>();
    final requests = <http.Request>[];
    final client = MockClient((request) {
      requests.add(request);
      return reply.future;
    });
    final c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()),
        coreFactory: () => SaathiCore(client: client));
    await c.load();
    await c.addConnection({
      'id': 'direct',
      'name': 'Direct',
      'type': 'openai',
      'url': 'https://example.test'
    }, 'fixture');
    await c.newSession(c.connections.single, 'response-model', 'instructions');
    final chat = c.current!;
    const override =
        OptimizerSelection(connectionId: 'direct', model: 'rewrite');
    await c.saveOptimizerSelection(override, chat: chat);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    final sending = c.send('Accepted input');
    for (var i = 0; i < 10 && requests.isEmpty; i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(requests, hasLength(1));
    expect(c.busy, isTrue);
    final admittedBody = requests.single.body;
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    expect(
        t
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Add connection'))
            .onPressed,
        isNull);
    await t.scrollUntilVisible(find.text('Chat prompt optimizer'), 200);
    await t.tap(find.text('Chat prompt optimizer'));
    await t.pumpAndSettle();
    await t.tap(find.text('Inherit global setting'));
    await t.pumpAndSettle();
    // The explicit rewrite preference affects future optimizations, never the
    // already accepted response, its source or its instructions.
    expect(c.optimizerOverride(chat), isNull);
    expect(c.busy, isTrue);
    expect(c.globalOptimizerSelection, isNull);
    expect(chat.model, 'response-model');
    expect(chat.systemPrompt, 'instructions');
    expect(c.current, same(chat));
    expect(requests, hasLength(1));
    expect(requests.single.body, admittedBody);
    reply.complete(http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Finished'}
            }
          ]
        }),
        200));
    for (var i = 0; i < 10 && c.busy; i++) {
      await t.pump();
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(await sending, isTrue);
    expect(chat.messages.last.content, 'Finished');
    expect(requests.single.method, 'POST');
    expect(jsonDecode(requests.single.body)['model'], 'response-model');
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
    client.close();
  });

  testWidgets('Settings add retries storage only and returns after secure save',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final secrets = _Secrets();
    final preferences = await SharedPreferences.getInstance();
    final c =
        ChatController(SaathiStore(preferences: preferences, secrets: secrets));
    await c.load();
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    await t.tap(find.text('Add connection'));
    await t.pumpAndSettle();
    await t.enterText(
        find.widgetWithText(TextFormField, 'Connection name'), 'Added');
    await t.enterText(find.widgetWithText(TextFormField, 'API base URL'),
        'https://example.test');
    await t.enterText(
        find.byKey(const Key('connection-key')), ' fixture-only-secret ');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Save connection'), 200,
        scrollable: find
            .descendant(
                of: find.byType(AddConnectionPage),
                matching: find.byType(Scrollable))
            .first);
    await t.tap(find.text('Save connection'));
    await t.pumpAndSettle();
    expect(find.byType(AddConnectionPage), findsOneWidget);
    expect(find.textContaining('Could not save securely'), findsOneWidget);
    expect(c.connections, isEmpty);
    expect((await c.store.load()).connections, isEmpty);
    secrets.failWrite = false;
    await t.scrollUntilVisible(find.text('Save connection'), 100,
        scrollable: find
            .descendant(
                of: find.byType(AddConnectionPage),
                matching: find.byType(Scrollable))
            .first);
    await t.tap(find.text('Save connection'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(c.connections.single['name'], 'Added');
    expect(
        await secrets.read(c.connections.single['id']), 'fixture-only-secret');
    expect(
        jsonEncode({
          for (final key in preferences.getKeys()) key: preferences.get(key)
        }),
        isNot(contains('fixture-only-secret')));
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byType(ChatHome), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  testWidgets(
      'settings sections remain reachable at 360px, 2x text and keyboard',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetViewInsets);
    final semantics = t.ensureSemantics();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final adapter = _Notifications();
    final notifications = ReplyNotifications(preferences, adapter: adapter);
    final updates = SaathiUpdateController(
        service: SaathiUpdateService(
            config: const UpdateConfig(),
            installed: UpdateVersion.parse('0.1.0', 1)));
    final c = ChatController(
        SaathiStore(preferences: preferences, secrets: MemorySecrets()))
      ..notifications = notifications;
    await c.load();
    await t.pumpWidget(SaathiUpdateHost(
        controller: updates,
        child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!),
            home: ChatHome(controller: c))));
    await t.pumpAndSettle();
    final settings = find.byTooltip('Settings');
    expect(
        t.getSemantics(settings),
        matchesSemantics(
            tooltip: 'Settings',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
            hasFocusAction: true,
            isFocusable: true));
    await t.tap(settings);
    await t.pumpAndSettle();
    expect(find.text('Current conversation'), findsNothing);
    await t.scrollUntilVisible(find.text('Global prompt optimizer'), 180);
    await t.tap(find.text('Global prompt optimizer'));
    await t.pumpAndSettle();
    expect(find.text('Selected: Not configured'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Notifications'), 180);
    final tile = find.widgetWithText(ListTile, 'Notifications');
    expect(t.getSize(tile).height, greaterThanOrEqualTo(48));
    expect(
        t.getSemantics(tile).getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue);
    expect(
        t
            .getSemantics(tile)
            .getSemanticsData()
            .hasAction(SemanticsAction.focus),
        isTrue);
    await t.tap(find.text('Notifications'));
    await t.pumpAndSettle();
    expect(adapter.permissions, 0);
    await t.tap(find.byType(SwitchListTile));
    await t.pumpAndSettle();
    expect(adapter.permissions, 1);
    expect(preferences.getBool(ReplyNotifications.preferenceKey), isTrue);
    await t.pageBack();
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('App updates'), 180);
    await t.tap(find.text('App updates'));
    await t.pumpAndSettle();
    expect(find.text('Current version: 0.1.0'), findsOneWidget);
    expect(find.textContaining('not configured'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Notifications'), -180);
    await t.ensureVisible(find.text('Notifications'));
    await t.pumpAndSettle();
    expect(find.text('Notifications').hitTestable(), findsOneWidget);
    await t.tap(find.text('Notifications'));
    await t.pumpAndSettle();
    expect(t.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
    await t.pageBack();
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byType(ChatHome), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
    notifications.dispose();
    updates.dispose();
    semantics.dispose();
  });
  testWidgets('open Settings never retargets the captured conversation',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await c.load();
    final first =
        ChatSession(id: 'first', connectionId: 'source', model: 'first-model');
    final second = ChatSession(
        id: 'second', connectionId: 'source', model: 'second-model');
    c.sessions.addAll([first, second]);
    c.current = first;
    const local = OptimizerSelection(connectionId: 'source', model: 'rewrite');
    await c.saveOptimizerSelection(local, chat: first);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Chat prompt optimizer'), 200);
    await t.pumpAndSettle();
    expect(find.text('Current conversation'), findsOneWidget);
    c.select(second);
    await t.pumpAndSettle();
    expect(find.text('Chat prompt optimizer'), findsNothing);
    expect(find.text('Current conversation'), findsNothing);
    expect(c.optimizerOverride(first), local);
    expect(c.optimizerOverride(second), isNull);
    expect(c.globalOptimizerSelection, isNull);
    expect(first.model, 'first-model');
    expect(second.model, 'second-model');
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
      'one Settings action opens scoped preferences and returns to draft',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await c.load();
    await c.addConnection({
      'id': 'direct',
      'name': 'Direct',
      'type': 'openai',
      'url': 'https://example.test'
    }, 'fixture-key');
    await c.newSession(c.connections.single, 'response-model', 'instructions');
    const global = OptimizerSelection(connectionId: 'direct', model: 'global');
    const local = OptimizerSelection(connectionId: 'direct', model: 'local');
    await c.saveOptimizerSelection(global);
    await c.saveOptimizerSelection(local, chat: c.current);
    final chat = c.current!;
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('composer')), 'Unsent draft');
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Connection settings'), findsNothing);
    expect(find.byTooltip('Chat prompt optimizer'), findsNothing);
    final settings = find.byTooltip('Settings');
    expect(t.getSize(settings).width, greaterThanOrEqualTo(48));
    expect(t.getSize(settings).height, greaterThanOrEqualTo(48));
    await t.tap(settings);
    await t.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(find.text('Connections'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Global prompt optimizer'), 200);
    await t.tap(find.text('Global prompt optimizer'));
    await t.pumpAndSettle();
    expect(find.text('Selected: Direct · global'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Chat prompt optimizer'), 200);
    await t.tap(find.text('Chat prompt optimizer'));
    await t.pumpAndSettle();
    expect(find.text('Selected: Direct · local'), findsOneWidget);
    await t.tap(find.text('Inherit global setting'));
    await t.pumpAndSettle();
    expect(c.optimizerOverride(chat), isNull);
    expect(c.globalOptimizerSelection, global);
    expect(c.optimizerSelection(chat), global);
    expect(chat.model, 'response-model');
    expect(chat.systemPrompt, 'instructions');
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('composer')), findsOneWidget);
    expect(
        t.widget<TextField>(find.byKey(const Key('composer'))).controller!.text,
        'Unsent draft');
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
