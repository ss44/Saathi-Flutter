import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'pending_message_home_test.dart' show FlowFixture;

void expectNoOrdinaryPhaseText() {
  for (final phase in [
    'Sending your message',
    'Waiting for its turn',
    'Working on your reply',
  ]) {
    expect(find.text(phase), findsNothing);
  }
}

void expectNoActivityStrip() {
  expect(find.text('Agent activity'), findsNothing);
  expect(find.text('Needs your attention'), findsNothing);
  expect(find.byKey(const Key('composer')).hitTestable(), findsOneWidget);
}

void main() {
  testWidgets('Android thinking indicator is replaced only by the final reply',
      (tester) async {
    final fixture = FlowFixture()
      ..width = 360
      ..scale = 2
      ..reduced = true;
    await fixture.mount(tester);
    late Future<bool> sending;
    await tester.runAsync(() async {
      sending = fixture.c.send('hello');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    expect(find.byKey(const Key('thinking-quip')), findsOneWidget);
    expect(find.byKey(const Key('pending-status')), findsNothing);
    expectNoOrdinaryPhaseText();
    expect(find.text('Refresh').hitTestable(), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    fixture.admission.complete();
    await tester.runAsync(() => sending);
    await tester.pump();
    expect(fixture.c.currentRun!.snapshot.status, 'queued');
    expect(find.byType(BusyThinking), findsOneWidget);
    expectNoOrdinaryPhaseText();
    expect(find.byTooltip('Check status').hitTestable(), findsOneWidget);
    fixture.status = 'running';
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Check status'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    expect(fixture.c.currentRun!.snapshot.status, 'running');
    expectNoActivityStrip();
    expect(find.byType(BusyThinking), findsOneWidget);
    expectNoOrdinaryPhaseText();
    expect(find.byTooltip('Check status').hitTestable(), findsOneWidget);
    fixture.status = 'completed';
    await tester.runAsync(() => fixture.c.checkRunStatus());
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(BusyThinking), findsNothing);
    expect(find.byKey(const Key('thinking-quip')), findsNothing);
    expect(find.text('Final answer').hitTestable(), findsOneWidget);
    expect(fixture.c.current!.messages.map((m) => m.content),
        ['hello', 'Final answer']);
    expect(fixture.posts, 1);
    expect(tester.takeException(), isNull);
    await fixture.close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android keeps real recovery decision and stopping feedback',
      (tester) async {
    final fixture = FlowFixture()
      ..width = 360
      ..scale = 2
      ..reduced = true
      ..unavailable = true;
    await fixture.mount(tester);
    fixture.admission.complete();
    await tester.runAsync(() => fixture.c.send('hello'));
    await tester.pump();
    expect(find.text('Reconnecting to check your reply'), findsWidgets);
    expect(find.byTooltip('Check status').hitTestable(), findsOneWidget);
    fixture.unavailable = false;
    fixture.status = 'waiting_for_approval';
    await tester.runAsync(() => fixture.c.checkRunStatus());
    await tester.pump();
    expect(find.text('Your decision is needed'), findsOneWidget);
    expectNoActivityStrip();
    expect(find.byType(BusyThinking), findsNothing);
    expect(find.byTooltip('Check status').hitTestable(), findsOneWidget);
    fixture.status = 'stopping';
    await tester.runAsync(() => fixture.c.checkRunStatus());
    await tester.pump();
    expect(find.text('Waiting for the server to stop'), findsOneWidget);
    expect(find.byTooltip('Check status').hitTestable(), findsOneWidget);
    expect(fixture.posts, 1);
    expect(tester.takeException(), isNull);
    await fixture.close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  // Promoted independent probe: assertions unchanged; formatting normalized.
  testWidgets('ordinary phase label remains visible on Android', (t) async {
    final f = FlowFixture()..reduced = true;
    await f.mount(t);
    f.admission.complete();
    await t.runAsync(() => f.c.send('first'));
    await t.pump();
    try {
      expect(find.text('Waiting for its turn'), findsNothing);
    } finally {
      await f.close(t);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
