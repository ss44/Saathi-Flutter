import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'review37_decision_lifecycle_test.dart' show DecisionFixture;

void main() {
  for (final clarify in [false, true]) {
    testWidgets(
        'independent control-sheet valid running read resumes exhausted polling: clarify=$clarify',
        (t) async {
      final f = DecisionFixture(clarify);
      await f.mount(t, 360);
      final op = f.c.currentRun!;
      final session = f.c.current!;
      f.unavailable = true;
      f.c.pauseRuns(false);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(seconds: 8));
        await f.flush(t);
      }
      expect(f.reads, 5);
      expect(f.c.runObservationProblem, contains('Use Check status'));
      f.expectDecision();
      final exhausted = f.requests.length;
      await t.pump(const Duration(seconds: 60));
      await f.flush(t);
      expect(f.requests, hasLength(exhausted));
      // Another client resolves the decision. This actual Review/Answer action
      // obtains a fresh authoritative original-run snapshot via the same GET.
      f.unavailable = false;
      f.pending = false;
      f.settledStatus = 'running';
      await t.tap(find.text(clarify ? 'Answer needed' : 'Review action'));
      await f.flush(t);
      await t.pump(const Duration(milliseconds: 300));
      expect(f.reads, greaterThan(5));
      expect(f.c.currentRun, same(op));
      expect(op.snapshot.state, RunState.running);
      expect(op.snapshot.pendingControls, isEmpty);
      await t.binding.handlePopRoute();
      await t.pump(const Duration(milliseconds: 300));
      await f.flush(t);
      final thinking = f.c.showPendingThinking;
      final observationProblem = f.c.runObservationProblem;
      final reads = f.reads;
      f.settledStatus = 'completed';
      await t.pump(const Duration(seconds: 2));
      await f.flush(t);
      final automaticReads = f.reads;
      final committed = op.committed;
      final messages = session.messages.map((m) => m.content).toList();
      expect(f.submissions, hasLength(1));
      expect(f.decisions, isEmpty);
      expect(f.c.current, same(session));
      expect(t.takeException(), isNull);
      await f.close(t);
      expect(observationProblem, isNull,
          reason:
              'A fresh authoritative control-sheet GET is a valid observation');
      expect(thinking, isTrue,
          reason: 'Valid running with no pending controls clears the decision');
      expect(automaticReads, reads + 1,
          reason:
              'The existing poll owner must resume after valid running recovery');
      expect(committed, isTrue);
      expect(messages, ['Original input', 'Original final answer']);
    });
  }
}
