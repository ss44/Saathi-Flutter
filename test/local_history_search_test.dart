import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/local_history_search.dart';

void main() {
  test(
      'literal queries use content only, preserve order and reflect message removal',
      () {
    final a = ChatSession(
        id: 'secret-id',
        connectionId: 'secret-connection',
        model: 'secret-model',
        systemPrompt: 'secret-prompt',
        messages: [
          ChatMessage(
              role: 'user',
              content: 'ordinary title',
              metadata: {'private': 'secret-metadata'}),
          ChatMessage(role: 'model', content: 'literal [.*] MATCH')
        ]);
    final b = ChatSession(
        id: 'b',
        connectionId: 'b',
        model: 'b',
        messages: [ChatMessage(role: 'user', content: 'MATCH title')]);
    expect(searchLocalHistory([b, a], 'match').map((m) => m.session), [b, a]);
    expect(searchLocalHistory([a], '[.*]').single.snippet, contains('[.*]'));
    expect(searchLocalHistory([a], 'secret'), isEmpty);
    a.messages.removeLast();
    expect(searchLocalHistory([a], 'match'), isEmpty);
    expect(searchLocalHistory([a], '  ').single.snippet, isNull);
  });
  for (final width in [390.0, 360.0]) {
    testWidgets(
        'clear, empty, deletion and lazy large history at $width with keyboard',
        (tester) async {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final c = ChatController(SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets()));
      await c.load();
      c.sessions.addAll(List.generate(
          2000,
          (i) => ChatSession(
                  id: '$i',
                  connectionId: 'source',
                  model: 'model',
                  messages: [
                    ChatMessage(role: 'user', content: 'Chat $i match')
                  ])));
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(width == 360 ? 2 : 1)),
              child: child!),
          home: ChatHome(controller: c)));
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      final search = find.byKey(const Key('local-history-search'));
      await tester.enterText(search, 'match');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      final list = find.descendant(
          of: find.byType(Drawer), matching: find.byType(ListView));
      final scrollable =
          find.descendant(of: list, matching: find.byType(Scrollable));
      tester.state<ScrollableState>(scrollable).position.jumpTo(
          tester.state<ScrollableState>(scrollable).position.maxScrollExtent);
      await tester.pumpAndSettle();
      // Lazy variable-height lists refine their estimated extent as rows appear.
      await tester.enterText(search, 'Chat 0 match');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Chat 0 match'), findsOneWidget);
      c.select(c.sessions.first);
      await c.clear();
      await tester.pumpAndSettle();
      expect(find.text('No matching conversations'), findsOneWidget);
      await tester.enterText(search, 'missing');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('No matching conversations'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(find.text('No matching conversations'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
  testWidgets('malformed saved data is not overwritten by searching',
      (tester) async {
    const raw = '[{"messages":"broken"}]';
    SharedPreferences.setMockInitialValues({'saathi.chats.v1': raw});
    final prefs = await SharedPreferences.getInstance();
    final c = ChatController(
        SaathiStore(preferences: prefs, secrets: MemorySecrets()));
    await c.load();
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('local-history-search')), 'anything');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('No matching conversations'), findsOneWidget);
    expect(prefs.getString('saathi.chats.v1'), raw);
    expect(c.readOnly, isTrue);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
      'drawer searches old assistant content and selects original without network',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var cores = 0;
    final c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()), coreFactory: () {
      cores++;
      throw StateError('No network allowed');
    });
    await c.load();
    final old = ChatSession(
        id: 'old',
        connectionId: 'original',
        model: 'old-model',
        messages: [
          ChatMessage(role: 'user', content: 'Old question'),
          ChatMessage(
              role: 'model',
              content:
                  '${'Earlier words ' * 80}Needle in the middle ${'later ' * 80}'),
          ChatMessage(role: 'user', content: 'latest unrelated')
        ]);
    final newer = ChatSession(
        id: 'new',
        connectionId: 'other',
        model: 'new-model',
        messages: [ChatMessage(role: 'user', content: 'Recent question')]);
    c.sessions.addAll([old, newer]);
    c.select(newer);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    final search = find.byKey(const Key('local-history-search'));
    expect(search, findsOneWidget);
    await tester.enterText(search, 'nEeDlE');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('Old question'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(Drawer), matching: find.text('Recent question')),
        findsNothing);
    expect(find.textContaining('Needle in the middle'), findsOneWidget);
    await tester.tap(find.text('Old question'));
    await tester.pumpAndSettle();
    expect(c.current, same(old));
    expect(c.current!.connectionId, 'original');
    expect(c.sessions.length, 2);
    expect(cores, 0);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
