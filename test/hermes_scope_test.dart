import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

void main() {
  testWidgets('Hermes-first delivery has no reachable new image or SAF action',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    addTearDown(c.dispose);
    await c.load();
    await c.addConnection(
        {'id': 'plain', 'name': 'Existing plain chat', 'type': 'openai'}, '');
    await c.newSession(c.connections.single, 'gpt-4o', '');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.enterText(
        find.byKey(const Key('composer')), 'Retained text draft');
    await tester.pump();
    await tester.longPress(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Attach image'), findsNothing);
    expect(find.text('Generate image'), findsNothing);
    expect(find.text('Optimize prompt'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text,
        'Retained text draft');
    await tester.pumpWidget(const SizedBox());
  });
}
