import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:saathi/ui/connections.dart';
import 'optimizer_settings_driver.dart';

import 'prompt_optimizer_acceptance_test.dart' as fixture;

Future<void> tabTo(WidgetTester tester, Finder target) async {
  final focus = Focus.of(tester.element(target));
  for (var i = 0; i < 60 && !focus.hasFocus; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
  }
  expect(focus.hasFocus, isTrue, reason: 'Control must be reachable using Tab');
  expect(target.hitTestable(), findsOneWidget,
      reason: 'Focus traversal must scroll the control into view');
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
        'nested optimizer keyboard choice at 360px/2x with keyboard in $brightness',
        (tester) async {
      tester.view.physicalSize = const Size(360, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final c = await fixture.controller(
          MemorySecrets(), (_) async => http.Response('{}', 200));
      for (var i = 0; i < 4; i++) {
        c.connections.add({
          'id': 'remote-$i',
          'name': 'Remote $i',
          'type': 'openai',
          'url': 'http://localhost:9998'
        });
      }
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(2),
                viewInsets: const EdgeInsets.only(bottom: 280)),
            child: child!),
        home: ConnectionsPage(controller: c),
      ));
      await openOptimizerSettings(tester);
      final source = find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Remote 3'));
      await tabTo(tester, source);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await fixture.flush(tester);
      final model = find.text('test');
      await tabTo(tester, model);
      expect(
          tester
              .getSemantics(
                  find.ancestor(of: model, matching: find.byType(ListTile)))
              .label,
          contains('test'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(c.globalOptimizerSelection,
          const OptimizerSelection(connectionId: 'remote-3', model: 'test'));
      expect(c.current!.model, 'test');
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      semantics.dispose();
    });
  }
}
