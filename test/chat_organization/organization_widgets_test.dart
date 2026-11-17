import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/chat_organization/organization_widgets.dart';

void main() {
  testWidgets(
      'shared persona creation selection cancellation and affected-chat disclosure',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final organization = ChatOrganization(
        OrganizationStorage(await SharedPreferences.getInstance()));
    await organization.load();
    const a = ConversationIdentity('c', 'a');
    const b = ConversationIdentity('c', 'b');
    final key = GlobalKey<ScaffoldState>();
    Future<void> open() => showConversationEdit(
        context: key.currentContext!,
        organization: organization,
        identity: a,
        fallbackInstructions: 'Original role',
        policy: (_) => PersonaEditPolicy.localInstructions,
        pendingReason: (_) => null);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            key: key,
            body: TextButton(
                onPressed: open, child: const Text('Open editor')))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New persona'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('persona-name')), 'Writing coach');
    await tester.enterText(
        find.byKey(const ValueKey('persona-instructions')), 'Explain simply.');
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(organization.personas, isEmpty);
    await tester.tap(find.text('New persona'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('persona-name')), 'Writing coach');
    await tester.enterText(
        find.byKey(const ValueKey('persona-instructions')), 'Explain simply.');
    await tester.tap(find.text('Save persona'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final id = organization.personas.single.id;
    expect(organization.entry(a).personaId, id);
    await organization.edit(b,
        displayName: 'Second chat',
        personaId: id,
        policy: PersonaEditPolicy.localInstructions,
        pendingReason: null);
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit shared persona'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 conversations'), findsOneWidget);
    expect(find.textContaining('Second chat'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('persona-instructions')), 'Use examples.');
    await tester.tap(find.text('Save persona'));
    await tester.pumpAndSettle();
    expect(organization.captureInstructions(b, fallback: '').instructions,
        'Use examples.');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  for (final width in [390.0, 360.0]) {
    testWidgets(
        'real drawer swipe archive restore edit and search at $width / 2x keyboard',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final organization = ChatOrganization(
          OrganizationStorage(await SharedPreferences.getInstance()));
      await organization.load();
      const id = ConversationIdentity('connection', 'chat');
      await organization.recordCompletion(id, 'answer');
      final scaffold = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!),
          home: Scaffold(
              key: scaffold,
              appBar: AppBar(title: const Text('Chat')),
              drawer: Drawer(
                  child: SafeArea(
                      child: ConversationOrganizationList(
                organization: organization,
                rows: const [
                  ConversationRowData(
                      identity: id,
                      title: 'Original question',
                      searchText: 'Original question',
                      state: ConversationWorkState.working)
                ],
                onSelect: (_) {},
                onEdit: (identity) => showConversationEdit(
                    context: scaffold.currentContext!,
                    organization: organization,
                    identity: identity,
                    fallbackInstructions: 'Default instructions',
                    policy: (_) => PersonaEditPolicy.localInstructions,
                    pendingReason: (_) => null),
              ))),
              body: const Text('History is untouched'))));
      // Use the native edge gesture, not a substitute drawer widget.
      await tester.dragFrom(const Offset(1, 350), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('Original question'), findsOneWidget);
      final titleX = tester.getTopLeft(find.text('Original question')).dx;
      await tester.drag(find.text('Original question'), const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Original question')).dx,
          lessThan(titleX - 100));
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      await tester.tap(find.byTooltip('Archive conversation'));
      await tester.pumpAndSettle();
      expect(organization.entry(id).archived, isTrue);
      expect(find.text('Original question'), findsNothing);
      expect(find.textContaining('1 need attention'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('archived-view')));
      await tester.pumpAndSettle();
      expect(find.text('Original question'), findsOneWidget);
      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(organization.entry(id).archived, isFalse);
      await tester.tap(find.byKey(const ValueKey('archived-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Conversation actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('conversation-name')), 'Renamed planning');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(organization.entry(id).displayName, 'Renamed planning');
      expect(organization.entry(id).unread, isTrue);
      expect(find.text('History is untouched'), findsOneWidget);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('conversation-search')), 'Renamed');
      await tester.pumpAndSettle();
      expect(find.text('Renamed planning'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
