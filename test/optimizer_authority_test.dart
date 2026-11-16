import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/optimizer_settings.dart';
import 'prompt_optimizer_acceptance_test.dart' as fixture;

void main() {
  for (final phase in ['secure read', 'HTTP']) {
    for (final change in [
      'setting round trip',
      'source round trip',
      'lifecycle round trip'
    ]) {
      testWidgets('$change during $phase cannot revive rewrite',
          (tester) async {
        final secrets = fixture.DelayedSecrets();
        final pending = Completer<http.Response>();
        var posts = 0;
        final c = await fixture.controller(secrets, (_) {
          posts++;
          return pending.future;
        });
        final draft = TextEditingController(text: 'Original');
        await fixture.open(tester, c, draft);
        await fixture.improve(tester);
        if (phase == 'HTTP') {
          secrets.pending.complete('fixture');
          await tester.pump();
          expect(posts, 1);
        }
        if (change == 'setting round trip') {
          await c.saveOptimizerSelection(
              const OptimizerSelection(connectionId: 'other', model: 'test'));
          await c.saveOptimizerSelection(
              const OptimizerSelection(connectionId: 'direct', model: 'test'));
        } else if (change == 'source round trip') {
          final source = c.connections.single;
          c.connections[0] = {...source};
          c.notifyListeners();
          c.connections[0] = source;
          c.notifyListeners();
        } else {
          c.setQueueBackground(true);
          c.setQueueBackground(false);
          c.notifyListeners();
        }
        if (phase == 'secure read') secrets.pending.complete('fixture');
        pending.complete(http.Response(fixture.response('STALE'), 200));
        await fixture.flush(tester);
        expect(posts, phase == 'HTTP' ? 1 : 0);
        expect(find.text('Apply'), findsNothing);
        expect(draft.text, 'Original');
        await fixture.cleanup(tester, c, draft);
      });
    }
  }
  testWidgets('catalog models cannot be selected after background and resume',
      (tester) async {
    final c = await fixture.controller(
        MemorySecrets(), (_) async => http.Response('{}', 200));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: OptimizerSettingsButton(controller: c))));
    await tester.tap(find.byTooltip('Global prompt optimizer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct'));
    await fixture.flush(tester);
    expect(find.text('test'), findsOneWidget);
    c.setQueueBackground(true);
    c.setQueueBackground(false);
    c.notifyListeners();
    await tester.pump();
    expect(find.text('test'), findsNothing);
    expect(find.byType(OptimizerSettingsDialog), findsOneWidget);
    await tester.tap(find.text('Catalog changed. Try again.'));
    await fixture.flush(tester);
    await tester.tap(find.text('test'));
    await tester.pumpAndSettle();
    expect(find.byType(OptimizerSettingsDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
