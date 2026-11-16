import 'dart:convert';
import 'dart:async';
import 'package:saathi/ui/optimizer_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'prompt_optimizer_acceptance_test.dart' as fixture;

class PopObserver extends NavigatorObserver {
  VoidCallback? onPop;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onPop?.call();
  }
}

void main() {
  for (final change in ['setting', 'source round trip']) {
    testWidgets(
        '$change revoked while Apply route pops cannot apply stale preview',
        (tester) async {
      final c = await fixture.controller(MemorySecrets(),
          (_) async => http.Response(fixture.response('Improved'), 200));
      final observer = PopObserver();
      final draft = TextEditingController(text: 'Original');
      await fixture.open(tester, c, draft, observers: [observer]);
      await fixture.improve(tester);
      await fixture.flush(tester);
      observer.onPop = () {
        if (change == 'setting') {
          unawaited(c.saveOptimizerSelection(null));
        } else {
          final source = c.connections.single;
          c.connections[0] = {...source};
          c.notifyListeners();
          c.connections[0] = source;
          c.notifyListeners();
        }
      };
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(draft.text, 'Original');
      expect(find.text('Undo'), findsNothing);
      await fixture.cleanup(tester, c, draft);
    });
  }
  for (final action in ['manual edit round trip', 'session round trip']) {
    testWidgets('$action cannot revive Undo over a newer draft',
        (tester) async {
      final c = await fixture.controller(MemorySecrets(),
          (_) async => http.Response(fixture.response('Improved'), 200));
      final draft = TextEditingController(text: 'Original');
      await fixture.open(tester, c, draft);
      await fixture.improve(tester);
      await fixture.flush(tester);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);
      if (action == 'manual edit round trip') {
        draft.text = 'New';
        draft.text = 'Improved';
      } else {
        final before = c.current;
        c.current =
            ChatSession(id: 'new', connectionId: 'direct', model: 'test');
        c.notifyListeners();
        c.current = before;
        c.notifyListeners();
      }
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
      expect(draft.text, 'Improved');
      await fixture.cleanup(tester, c, draft);
    });
  }
  testWidgets('missing verified model never falls back to chat response model',
      (tester) async {
    var posts = 0;
    final c = await fixture.controller(MemorySecrets(), (request) async {
      if (request.method == 'POST') posts++;
      return http.Response(
          jsonEncode({
            'data': [
              {'id': 'replacement'}
            ]
          }),
          200);
    }, catalogFixture: false);
    final draft = TextEditingController(text: 'Private draft');
    await fixture.open(tester, c, draft);
    await fixture.flush(tester);
    expect(find.textContaining('no longer in this connection'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Improve'))
            .onPressed,
        isNull);
    expect(posts, 0);
    expect(draft.text, 'Private draft');
    await fixture.cleanup(tester, c, draft);
  });
}
