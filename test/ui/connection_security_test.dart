import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/connections.dart';

void main() {
  testWidgets('non-loopback HTTP is rejected without a supported exception',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await c.load();
    await tester
        .pumpWidget(MaterialApp(home: AddConnectionPage(controller: c)));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Connection name'), 'Remote');
    await tester.enterText(find.widgetWithText(TextFormField, 'API base URL'),
        'http://remote.example');
    await tester.ensureVisible(find.text('Save connection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();
    expect(c.connections, isEmpty);
    expect(
        find.text(
            'Use HTTPS for remote servers. HTTP is only supported on loopback.'),
        findsOneWidget);
  });
}
