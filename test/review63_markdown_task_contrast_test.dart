import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
        'rendered Markdown task icons have legible contrast in ${brightness.name}',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets());
      await store.saveChats([
        {
          'id': 'review-task-list',
          'connectionId': 'missing',
          'model': 'fixture',
          'messages': [
            {
              'role': 'assistant',
              'content': '- [x] Completed item\n- [ ] Pending item'
            }
          ]
        }
      ]);
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(SaathiApp(store: store));
      await tester.pumpAndSettle();
      final row = find.byType(MessageView);
      expect(row, findsOneWidget);
      final bubble = tester
          .widgetList<Container>(
              find.descendant(of: row, matching: find.byType(Container)))
          .firstWhere((c) => c.decoration is BoxDecoration);
      final background = (bubble.decoration! as BoxDecoration).color!;
      for (final icon in [Icons.check_box, Icons.check_box_outline_blank]) {
        final finder = find.descendant(of: row, matching: find.byIcon(icon));
        expect(finder, findsOneWidget);
        final foreground = tester.widget<Icon>(finder).color!;
        final a = foreground.computeLuminance();
        final b = background.computeLuminance();
        final contrast = ((a > b ? a : b) + 0.05) / ((a > b ? b : a) + 0.05);
        debugPrint(
            'REVIEW63 requested=${brightness.name} rendered=${Theme.of(tester.element(row)).brightness.name} foreground=$foreground background=$background contrast=$contrast');
        expect(contrast, greaterThanOrEqualTo(3.0),
            reason:
                'Task state icons must be visible against their actual assistant bubble');
      }
      expect(tester.takeException(), isNull);
    });
  }
}
