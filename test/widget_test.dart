import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
  testWidgets(
      'empty startup has no fake chat and offers a real connection form',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    await tester.pumpWidget(SaathiApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('A little space to think.'), findsOneWidget);
    expect(find.text('Can you help me plan tomorrow?'), findsNothing);
    await tester.tap(find.byTooltip('Connection settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add connection'));
    await tester.pumpAndSettle();
    expect(
        find.widgetWithText(TextFormField, 'Connection name'), findsOneWidget);
    expect(
        find.widgetWithText(TextFormField, 'API key / token'), findsOneWidget);
  });
}
