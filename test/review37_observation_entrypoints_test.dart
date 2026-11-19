import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_controls/agent_controls.dart';

import 'review37_control_refresh_test.dart' as readonly;
import 'review37_successful_decision_test.dart' show DecisionFixture;

class ObservationFixture extends DecisionFixture {
  ObservationFixture(super.clarify);
  Map<String, dynamic>? replacement;

  @override
  Map<String, dynamic> snapshot() => replacement ?? super.snapshot();

  Future<void> exhaust(WidgetTester t) async {
    unavailable = true;
    c.pauseRuns(false);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(seconds: 8));
      await flush(t);
    }
    expect(reads, 5);
    expect(c.runObservationProblem, contains('Use Check status'));
    final count = requests.length;
    await t.pump(const Duration(seconds: 60));
    await flush(t);
    expect(requests, hasLength(count));
    unavailable = false;
  }

  Future<AgentControlsController?> open(WidgetTester t) async {
    final opening = c.openRunControls(isOwnerCurrent: () => true);
    await flush(t);
    return opening;
  }
}

void main() {
  for (final clarify in [false, true]) {
    for (final invalid in [
      'unavailable',
      'missing status',
      'unrecognized status',
      'invalid generation',
      'missing controls',
      'invalid controls type',
      'mismatched control generation',
    ]) {
      testWidgets(
          'control refresh after exhaustion rejects $invalid; clarify=$clarify',
          (t) async {
        final f = ObservationFixture(clarify);
        await f.mount(t, 360);
        final op = f.c.currentRun!;
        final key = op.key;
        final payload = op.payload;
        final journalKey = 'run.v1.${f.c.current!.id}';
        await f.exhaust(t);
        final journal =
            await t.runAsync(() => f.c.store.secrets.read(journalKey));
        f.replacement = f.snapshot();
        switch (invalid) {
          case 'unavailable':
            f.unavailable = true;
          case 'missing status':
            f.replacement!.remove('status');
          case 'unrecognized status':
            f.replacement!['status'] = 'not_a_status';
          case 'invalid generation':
            f.replacement!['execution_generation'] = -1;
          case 'missing controls':
            f.replacement!.remove('pending_controls');
          case 'invalid controls type':
            f.replacement!['pending_controls'] = 'not controls';
          case 'mismatched control generation':
            (f.replacement!['pending_controls'] as List)
                .single['execution_generation'] = 2;
        }
        final panel = await f.open(t);
        expect(panel, isNotNull);
        expect(
            panel!.message,
            contains(invalid == 'mismatched control generation'
                ? 'cannot be shown safely'
                : 'Could not refresh'));
        expect(f.c.runObservationProblem, contains('Use Check status'));
        expect(f.c.showPendingThinking, isFalse);
        expect(f.reads, 6);
        final count = f.requests.length;
        await t.pump(const Duration(seconds: 60));
        await f.flush(t);
        expect(f.requests, hasLength(count));
        if (!['mismatched control generation', 'missing controls']
            .contains(invalid)) {
          expect(await t.runAsync(() => f.c.store.secrets.read(journalKey)),
              journal);
        }
        expect(f.c.currentRun, same(op));
        expect(op.key, key);
        expect(op.payload, payload);
        expect(f.c.current!.messages, isEmpty);
        expect(f.submissions, hasLength(1));
        expect(f.decisions, isEmpty);
        panel.dispose();
        await f.close(t);
      });
    }

    for (final status in [
      'queued',
      'started',
      'running',
      'unknown',
      'completed',
      'failed',
      'cancelled'
    ]) {
      testWidgets(
          'control refresh recovers authoritative $status; clarify=$clarify',
          (t) async {
        final f = ObservationFixture(clarify);
        await f.mount(t, 390);
        final op = f.c.currentRun!;
        final session = f.c.current!;
        final payload = op.payload;
        await f.exhaust(t);
        f.pending = false;
        f.settledStatus = status;
        final panel = await f.open(t);
        expect(panel, isNotNull);
        expect(f.reads, 6);
        expect(f.c.runObservationProblem, isNull);
        expect(op.snapshot.status, status);
        expect(f.c.currentRun, same(op));
        final ongoing = ['queued', 'started', 'running'].contains(status);
        expect(f.c.showPendingThinking, ongoing);
        panel!.dispose();
        if (ongoing) {
          // A new failure streak is bounded, even after valid control recovery.
          f.unavailable = true;
          for (var i = 0; i < 6; i++) {
            await t.pump(const Duration(seconds: 8));
            await f.flush(t);
          }
          expect(f.reads, 10);
          expect(f.c.runObservationProblem, contains('Use Check status'));
        } else {
          expect(op.committed, status != 'unknown');
        }
        final count = f.requests.length;
        await t.pump(const Duration(seconds: 60));
        await f.flush(t);
        expect(f.requests, hasLength(count));
        expect(f.c.current, same(session));
        expect(f.submissions, hasLength(1));
        expect(f.submissions.single.body, payload);
        expect(f.submissions.single.headers['Idempotency-Key'], op.key);
        expect(f.decisions, isEmpty);
        await f.close(t);
      });
    }

    for (final boundary in ['selection', 'source', 'lifecycle']) {
      testWidgets(
          'delayed control read cannot recover revoked $boundary; clarify=$clarify',
          (t) async {
        final f = ObservationFixture(clarify);
        await f.mount(t, 360);
        final session = f.c.current!;
        final op = f.c.currentRun!;
        await f.exhaust(t);
        final originalData = jsonEncode(op.data);
        final journalKey = 'run.v1.${session.id}';
        final journal =
            await t.runAsync(() => f.c.store.secrets.read(journalKey));
        f.holdRead = Completer<void>();
        f.pending = false;
        f.settledStatus = 'running';
        final opening = f.c.openRunControls(isOwnerCurrent: () => true);
        await f.flush(t);
        expect(f.reads, 6);
        if (boundary == 'selection') {
          await t.runAsync(
              () => f.c.newSession(f.c.connections.single, 'other', ''));
          f.c.select(session);
        } else if (boundary == 'source') {
          await t.runAsync(() => f.c.updateConnection(
              'original', {...f.c.connections.single},
              apiKey: 'replacement-fixture'));
        } else {
          // A fresh foreground grant must not revive this old controls owner.
          f.c.pauseRuns(true);
          f.c.pauseRuns(false);
        }
        final problem = f.c.runObservationProblem;
        f.holdRead!.complete();
        await f.flush(t);
        expect(await opening, isNull);
        expect(f.c.runObservationProblem, problem);
        expect(jsonEncode(op.data), originalData);
        expect(await t.runAsync(() => f.c.store.secrets.read(journalKey)),
            journal);
        expect(f.c.current, same(session));
        expect(f.c.currentRun, same(op));
        expect(f.submissions, hasLength(1));
        expect(f.decisions, isEmpty);
        expect(f.reads, 6);
        await f.close(t);
      });
    }

    testWidgets(
        'successful decision recovery preserves intentional queue pause; clarify=$clarify',
        (t) async {
      final f = ObservationFixture(clarify);
      await f.mount(t, 360);
      final op = f.c.currentRun!;
      await f.exhaust(t);
      f.c.submit('Held follower');
      f.c.pauseQueue('Paused by you');
      await t.tap(find.text(clarify ? 'Answer needed' : 'Review action'));
      await f.flush(t);
      await t.pump(const Duration(milliseconds: 300));
      if (clarify) {
        await t.tap(find.text('A'));
        await t.pump();
      }
      final answer =
          find.widgetWithText(FilledButton, clarify ? 'Send' : 'Allow once');
      await t.ensureVisible(answer);
      await t.tap(answer);
      await f.flush(t);
      expect(f.reads, 8);
      expect(f.c.runObservationProblem, isNull);
      expect(f.c.showPendingThinking, isTrue);
      expect(f.decisions, hasLength(1));
      await t.binding.handlePopRoute();
      await t.pump(const Duration(milliseconds: 300));
      f.settledStatus = 'completed';
      await t.pump(const Duration(seconds: 2));
      await f.flush(t);
      expect(f.reads, 9);
      expect(op.committed, isTrue);
      expect(f.c.current!.messages.map((m) => m.content),
          ['Original input', 'Original final answer']);
      expect(f.c.queueStatus, 'Paused by you');
      expect(f.c.outbox.single.text, 'Held follower');
      expect(f.submissions, hasLength(1));
      expect(f.decisions, hasLength(1));
      final count = f.requests.length;
      await t.pump(const Duration(seconds: 60));
      await f.flush(t);
      expect(f.requests, hasLength(count));
      await f.close(t);
    });

    testWidgets(
        'failed actual decision never resumes thinking; clarify=$clarify',
        (t) async {
      final f = readonly.DecisionFixture(clarify);
      await f.mount(t, 360);
      f.c.pauseRuns(false);
      f.unavailable = true;
      for (var i = 0; i < 4; i++) {
        final check = f.c.checkRunStatus();
        await f.flush(t);
        await check;
      }
      expect(f.reads, 5);
      f.unavailable = false;
      await t.tap(find.text(clarify ? 'Answer needed' : 'Review action'));
      await f.flush(t);
      await t.pump(const Duration(milliseconds: 300));
      if (clarify) {
        await t.tap(find.text('A'));
        await t.pump();
      }
      final answer =
          find.widgetWithText(FilledButton, clarify ? 'Send' : 'Allow once');
      await t.ensureVisible(answer);
      await t.tap(answer);
      await f.flush(t);
      expect(f.reads, 8);
      expect(find.textContaining('Response was not confirmed'), findsOneWidget);
      expect(f.c.showPendingThinking, isFalse);
      expect(f.c.pendingStatus, 'Your decision is needed');
      expect(f.c.currentRun!.snapshot.pendingControls, isNotEmpty);
      expect(f.decisions, hasLength(1));
      expect(f.submissions, hasLength(1));
      await t.binding.handlePopRoute();
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(seconds: 2));
      await f.flush(t);
      expect(f.reads, 9);
      expect(f.c.showPendingThinking, isFalse);
      expect(f.c.currentRun!.committed, isFalse);
      expect(f.c.current!.messages, isEmpty);
      expect(f.decisions, hasLength(1));
      expect(f.submissions, hasLength(1));
      await f.close(t);
    });
  }
}
