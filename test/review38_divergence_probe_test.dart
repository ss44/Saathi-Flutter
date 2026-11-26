import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'review38_history_refresh_test.dart' show RefreshFixture;
import 'ui/remote_participation_test.dart' show network;

void main() {
  testWidgets(
      'divergent idle remote history cannot silently report a ready refreshed chat',
      (t) async {
    final f = RefreshFixture();
    await t.runAsync(() async {
      await f.start();
      await f.open();
    });
    addTearDown(f.close);
    final original = f.c.current!;
    final before = [...original.messages];
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: f.c)));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const Key('composer')), 'private retained draft');
    f.rows = [
      {'id': 1, 'role': 'user', 'content': 'Original input'},
      {
        'id': 2,
        'role': 'assistant',
        'content': 'Authoritative corrected answer'
      },
      {'id': 3, 'role': 'assistant', 'content': 'Authoritative later answer'},
    ];
    await t.tap(find.byTooltip('Settings'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Browse remote sessions'));
    await network(t);
    final row = find.descendant(
        of: find.byType(RemoteSessionsPage),
        matching: find.text('External chat'));
    await t.ensureVisible(row);
    await t.tap(row);
    await network(t);
    await t.pumpAndSettle();
    expect(f.c.current, same(original));
    expect(original.messages, before,
        reason: 'Do not invent destructive conflict resolution');
    expect(f.reads, 3);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
    final stayedAtFailure =
        find.byType(RemoteHistoryPage).evaluate().isNotEmpty;
    final explicitWarning = f.c.error != null;
    final readOnly = f.c.readOnly;
    await t.pumpWidget(const SizedBox());
    expect(stayedAtFailure || explicitWarning || readOnly, isTrue,
        reason:
            'Unresolved authoritative divergence must not silently open stale history as ready-to-continue success');
  });
}
