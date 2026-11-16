import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/chat_home.dart';

void main() {
  for (final width in [390.0, 360.0]) {
    testWidgets(
        'edit form scrolls Save into keyboard viewport at $width and 2x text',
        (t) async {
      t.view.physicalSize = Size(width, 800);
      t.view.devicePixelRatio = 1;
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetViewInsets);
      SharedPreferences.setMockInitialValues({});
      final c = ChatController(SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets()));
      await c.load();
      final v = <String, dynamic>{
        'id': 'fixture',
        'name': 'Fixture',
        'type': 'openai',
        'url': 'https://example.test'
      };
      await c.addConnection(v, 'fixture-secret');
      await t.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!),
          home: AddConnectionPage(controller: c, connection: v)));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(find.text('Save connection'), 250,
          scrollable: find
              .descendant(
                  of: find.byType(ListView), matching: find.byType(Scrollable))
              .first);
      await t.ensureVisible(find.text('Save connection'));
      await t.pumpAndSettle();
      expect(find.text('Save connection').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }
  testWidgets(
      'swiping another row closes first; menu delete commits only after confirmation',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await c.load();
    for (final id in ['First', 'Second']) {
      await c.addConnection({
        'id': id,
        'name': id,
        'type': 'openai',
        'url': 'https://example.test'
      }, 'fixture-key');
    }
    await t.pumpWidget(MaterialApp(home: ConnectionsPage(controller: c)));
    final first = t.getTopLeft(find.text('First'));
    final second = t.getTopLeft(find.text('Second'));
    await t.drag(find.text('First'), const Offset(-400, 0));
    await t.pumpAndSettle();
    await t.drag(find.text('Second'), const Offset(-400, 0));
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.text('First')), first);
    expect(t.getTopLeft(find.text('Second')).dx, second.dx - 160);
    expect(find.text('Edit'), findsOneWidget);
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(c.connections, hasLength(2));
    await t.tap(find.text('Delete').last);
    await t.pumpAndSettle();
    expect(c.connections.single['id'], 'First');
    expect((await c.store.load()).connections.single['id'], 'First');
    expect(await c.store.secrets.read('Second'), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  testWidgets('missing connection shows read-only and disables composer',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await c.load();
    c.current = ChatSession(
        id: 'fixture-chat',
        connectionId: 'gone',
        model: 'fixture',
        systemPrompt: '');
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    expect(
        find.text(
            'Read-only · This connection was removed or changed. Start a new conversation to send messages.'),
        findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('composer'))).enabled,
        isFalse);
  });
  testWidgets(
      'full swipe only reveals; menu edits prefilled masked key and cancel keeps connection',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await c.load();
    await c.addConnection({
      'id': 'fixture',
      'name': 'Fixture',
      'type': 'hermes',
      'url': 'https://example.test'
    }, 'synthetic-key');
    await t.pumpWidget(MaterialApp(home: ConnectionsPage(controller: c)));
    final before = t.getTopLeft(find.text('Fixture'));
    await t.drag(find.text('Fixture'), const Offset(-700, 0));
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.text('Fixture')).dx, lessThan(before.dx - 100));
    expect(c.connections, hasLength(1));
    expect(find.text('Edit'), findsOneWidget);
    expect(find.byTooltip('Browse remote sessions'), findsOneWidget);
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.text('Edit connection'), findsOneWidget);
    expect(find.text('Fixture'), findsOneWidget);
    final key = t.widget<TextField>(find.descendant(
        of: find.byKey(const Key('connection-key')),
        matching: find.byType(TextField)));
    expect(key.obscureText, isTrue);
    await t.tap(find.byTooltip('Show API key'));
    await t.pump();
    expect(
        t
            .widget<TextField>(find.descendant(
                of: find.byKey(const Key('connection-key')),
                matching: find.byType(TextField)))
            .obscureText,
        isFalse);
    final nav = Navigator.of(t.element(find.byType(AddConnectionPage)));
    nav.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Cover'))));
    await t.pumpAndSettle();
    nav.pop();
    await t.pumpAndSettle();
    expect(
        t
            .widget<TextField>(find.descendant(
                of: find.byKey(const Key('connection-key')),
                matching: find.byType(TextField)))
            .obscureText,
        isTrue);
    await t.tap(find.byTooltip('Show API key'));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(
        t
            .widget<TextField>(find.descendant(
                of: find.byKey(const Key('connection-key')),
                matching: find.byType(TextField)))
            .obscureText,
        isTrue);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.scrollUntilVisible(find.text('Cancel'), 250,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(c.connections.single['name'], 'Fixture');
    await t.tap(find.byTooltip('Connection actions'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete').last);
    await t.pumpAndSettle();
    expect(find.text('Delete “Fixture”?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(c.connections, hasLength(1));
  });
}
