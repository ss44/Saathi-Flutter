import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises either the pinned base entry or #62's unified Settings entry.
/// No controller calls substitute for the user's navigation or selection.
Future<void> openOptimizerSettings(WidgetTester tester,
    {bool chat = false}) async {
  final label = chat ? 'Chat prompt optimizer' : 'Global prompt optimizer';
  final originalEntry = find.byTooltip(label);
  if (originalEntry.evaluate().isNotEmpty) {
    await tester.tap(originalEntry);
  } else {
    if (find.widgetWithText(ListTile, label).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
    }
    final row = find.widgetWithText(ListTile, label);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
  }
  await tester.pumpAndSettle();
}

Future<void> returnFromSettings(WidgetTester tester) async {
  final back = find.byTooltip('Back');
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back);
    await tester.pumpAndSettle();
  }
}
