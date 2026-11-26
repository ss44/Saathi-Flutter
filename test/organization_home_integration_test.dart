import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/chat_organization/organization_widgets.dart';
import 'organization_controller_integration_test.dart'
    show ControlledOrganizationStorage;

Future<ChatController> makeController() async {
  SharedPreferences.setMockInitialValues({});
  final c = ChatController(
      SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets()),
      coreFactory: () => SaathiCore(
          client: MockClient((_) async => http.Response(
              '{"choices":[{"message":{"content":"answer"}}]}', 200))));
  await c.load();
  await c.addConnection(
      {'id': 'a', 'name': 'Connection', 'type': 'openai'}, 'fixture');
  await c.newSession(c.connections.single, 'model', 'Original role');
  c.current!.messages.add(ChatMessage(role: 'user', content: 'Original title'));
  await c.persist();
  return c;
}

void main() {
  testWidgets(
      'unsaved organization metadata blocks Send and optimizer without losing its draft',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = ControlledOrganizationStorage(prefs);
    final c = ChatController(
        SaathiStore(preferences: prefs, secrets: MemorySecrets()),
        organizationStorage: storage);
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', '');
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('composer')), 'Preserve this draft');
    storage.fail = true;
    await expectLater(
        c.organization.setArchived(c.identityOf(c.current!), true),
        throwsStateError);
    await tester.pumpAndSettle();
    await tester.longPress(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Enhance prompt'), findsNothing);
    expect(c.outbox, isEmpty);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text,
        'Preserve this draft');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  for (final width in [390.0, 360.0]) {
    testWidgets(
        'actual ChatHome rename/archive/restore/search preserves long draft at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await makeController();
      final session = c.current!;
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(
                  size: Size(width, 900),
                  textScaler: TextScaler.linear(width == 360 ? 2 : 1),
                  viewInsets: const EdgeInsets.only(bottom: 260)),
              child: ChatHome(controller: c))));
      await tester.pumpAndSettle();
      final draft = List.filled(20, 'A long draft').join(' ');
      await tester.enterText(find.byKey(const Key('composer')), draft);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationActionRow), findsOneWidget);
      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('conversation-name')), 'Renamed chat');
      await tester.ensureVisible(find.text('Save').last);
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(c.displayTitle(session), 'Renamed chat');
      await tester.enterText(
          find.byKey(const Key('local-history-search')), 'Renamed');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(ConversationActionRow), findsOneWidget);
      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive').last);
      await tester.pumpAndSettle();
      expect(c.organization.entry(c.identityOf(session)).archived, isTrue);
      expect(find.byType(ConversationActionRow), findsNothing);
      await tester.tap(find.byKey(const Key('archived-view')));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationActionRow), findsOneWidget);
      await tester.drag(
          find.byType(ConversationActionRow), const Offset(-200, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(c.organization.entry(c.identityOf(session)).archived, isFalse);
      Navigator.of(tester.element(find.byType(ChatHome))).pop();
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.text('Renamed chat')),
          findsOneWidget);
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('composer')))
              .controller!
              .text,
          draft);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets(
      'actual ChatHome creates and attaches a persistent reusable assistant role without changing provider',
      (tester) async {
    final c = await makeController();
    final session = c.current!;
    final connection = c.connections.single;
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('composer')), 'Keep my draft');
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Conversation actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New persona'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('persona-name')), 'Language tutor');
    await tester.enterText(find.byKey(const ValueKey('persona-instructions')),
        'Explain with examples.');
    await tester.tap(find.text('Save persona'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    final persona = c.organization.personas.single;
    expect(persona.name, 'Language tutor');
    expect(c.organization.entry(c.identityOf(session)).personaId, persona.id);
    expect(
        c.organization
            .captureInstructions(c.identityOf(session), fallback: '')
            .instructions,
        'Explain with examples.');
    expect(c.connections.single, same(connection));
    Navigator.of(tester.element(find.byType(ChatHome))).pop();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text,
        'Keep my draft');
    await tester.pumpWidget(const SizedBox());
    final store = c.store;
    c.dispose();
    final reload = ChatController(store);
    await reload.load();
    expect(reload.organization.personas.single.instructions,
        'Explain with examples.');
    expect(
        reload.organization.entry(reload.identityOf(reload.current!)).personaId,
        persona.id);
    reload.dispose();
  });

  testWidgets(
      'actual answer body visibility acknowledges only known completion and never behind drawer/offscreen',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final c = await makeController();
    final session = c.current!;
    final identity = c.identityOf(session);
    session.messages.addAll([
      ChatMessage(
          role: 'model',
          content: List.filled(180, 'Older context line').join('\n\n')),
      ChatMessage(
          role: 'model',
          content: 'New authoritative answer',
          id: 'stable-reply',
          metadata: {'authoritativeCompletion': true})
    ]);
    await c.organization.recordCompletion(identity, 'stable-reply');
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.pumpAndSettle();
    expect(c.organization.entry(identity).unread, isTrue);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    final list = find
        .ancestor(
            of: find.byType(MessageView).first,
            matching: find.byType(Scrollable))
        .first;
    final scrollable = tester.state<ScrollableState>(list);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(c.organization.entry(identity).unread, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    Navigator.of(tester.element(find.byType(ChatHome))).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(c.organization.entry(identity).unread, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(c.organization.entry(identity).unread, isFalse);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
      'actual ChatHome drawer edge-swipe shows archived attention count',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await makeController();
    final session = c.current!;
    final identity = c.identityOf(session);
    await c.organization.recordCompletion(identity, 'unread-reply');
    await c.organization.setArchived(identity, true);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.pumpAndSettle();
    expect(find.text('Archived (1, 1 need attention)'), findsNothing);
    await tester.dragFrom(const Offset(1, 350), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text('Archived (1, 1 need attention)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
