import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/connections.dart';

void main() {
  testWidgets('whitespace-only edit preserves the stored key', (t) async {
    SharedPreferences.setMockInitialValues({});
    final controller = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    addTearDown(controller.dispose);
    await controller.load();
    final connection = <String, dynamic>{
      'id': 'fixture',
      'name': 'Fixture',
      'type': 'openai',
      'url': 'https://example.test'
    };
    await controller.addConnection(connection, 'fixture-old-key');
    await t.pumpWidget(MaterialApp(
        home:
            AddConnectionPage(controller: controller, connection: connection)));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('connection-key')), '   ');
    await t.scrollUntilVisible(find.text('Save connection'), 250,
        scrollable: find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);
    await t.tap(find.text('Save connection'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(await controller.store.readConnectionSecret('fixture'),
        'fixture-old-key');
    await t.pumpWidget(const SizedBox.shrink());
  });
}
