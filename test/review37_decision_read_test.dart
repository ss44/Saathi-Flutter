import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'pending_message_home_test.dart' show FlowFixture;

void main() {
  for (final width in [360.0, 390.0]) {
    testWidgets(
        'independent: failed observation must not revive thinking over a known decision at $width',
        (t) async {
      final f = FlowFixture()
        ..width = width
        ..scale = 2
        ..status = 'waiting_for_approval';
      await f.mount(t);
      f.admission.complete();
      await t.runAsync(() => f.c.send('Original input'));
      await t.pump();
      final original = f.c.currentRun!;
      expect(original.snapshot.state, RunState.waitingForApproval);
      expect(f.c.showPendingThinking, isFalse);
      expect(find.byType(BusyThinking), findsNothing);
      f.unavailable = true;
      await t.runAsync(() => f.c.checkRunStatus());
      await t.pump();
      await t.drag(find.byType(ListView).first, const Offset(0, -1600));
      await t.pump(const Duration(milliseconds: 300));
      final thinking = f.c.showPendingThinking;
      final mountedThinking = find.byType(BusyThinking).evaluate().length;
      expect(f.c.currentRun, same(original));
      expect(original.snapshot.state, RunState.waitingForApproval);
      expect(f.c.runPending, isTrue);
      expect(f.posts, 1);
      expect(f.c.current!.messages, isEmpty);
      await f.close(t);
      expect(thinking, isFalse,
          reason:
              'A failed read is not evidence that the existing user decision was answered');
      expect(mountedThinking, 0,
          reason: 'Actual ChatHome must retain its decision guard');
    });
  }
}
