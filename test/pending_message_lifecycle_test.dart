import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

import 'gateway/canonical_combined_controller_test.dart' as native;
import 'pending_message_home_test.dart' show FlowFixture;

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets('next Runs turn thinks before discovery completes', (t) async {
    final f = FlowFixture();
    await f.mount(t);
    final scopes = <ScopedRunSnapshot>[];
    final subscription = f.c.scopedRunSnapshots.listen(scopes.add);
    f.admission.complete();
    await t.runAsync(() => f.c.send('first'));
    f.c.observeRunEvent(scopes.last,
        {'event': 'tool.started', 'run_id': 'original', 'tool': 'search'},
        cursor: '1');
    expect(f.c.reportedActivity, 'Using search');
    f.status = 'completed';
    await t.runAsync(f.c.checkRunStatus);
    final gate = f.discovery = Completer<void>();
    late Future<bool> sending;
    await t.runAsync(() async {
      sending = f.c.send('second');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await t.pump();
    try {
      expect(f.c.showPendingThinking, isTrue);
      expect(find.byType(BusyThinking), findsOneWidget);
      expect(f.c.reportedActivity, isNull,
          reason: 'Previous-turn activity is not evidence about new work');
      expect(f.posts, 1);
    } finally {
      gate.complete();
      await t.runAsync(() => sending);
      await t.runAsync(subscription.cancel);
      await f.close(t);
    }
  });
  for (final width in [360.0, 390.0]) {
    for (final lane in ['gateway.fifo', 'gateway.journal']) {
      testWidgets(
          'next native turn thinks during $lane save at $width',
          (t) => HttpOverrides.runWithHttpOverrides(() async {
                t.view.devicePixelRatio = 1;
                t.view.physicalSize = Size(width, 800);
                t.view.viewInsets = const FakeViewPadding(bottom: 240);
                t.platformDispatcher.textScaleFactorTestValue = 2;
                addTearDown(() {
                  t.view.resetDevicePixelRatio();
                  t.view.resetPhysicalSize();
                  t.view.resetViewInsets();
                  t.platformDispatcher.clearTextScaleFactorTestValue();
                });
                late ChatController c;
                late native.NativeHost host;
                late native.GateSecrets secrets;
                await t.runAsync(() async {
                  final result = await native.setup();
                  c = result.$1;
                  host = result.$2;
                  secrets = result.$3;
                  await c.send('first');
                  host.terminal = true;
                  await c.refreshCanonical();
                  expect(c.runPending, isFalse);
                  host.terminal = false;
                });
                t.binding
                    .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
                await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
                // Start at the live edge; scrolled-up/long-history following is
                // covered independently by the retained combined-home suite.
                await t.drag(
                    find.byType(ListView).first, const Offset(0, -1600));
                await t.pumpAndSettle();
                final gate = secrets.gate = Completer<void>();
                secrets.gatePrefix = lane;
                await t.enterText(find.byKey(const Key('composer')), 'second');
                await t.pump();
                await t.tap(find.byTooltip('Send'));
                await t.pump();
                await t.runAsync(() =>
                    Future<void>.delayed(const Duration(milliseconds: 10)));
                for (var i = 0; i < 8; i++) {
                  await t.pump(const Duration(milliseconds: 50));
                }
                try {
                  expect(c.showPendingThinking, isTrue,
                      reason:
                          'saving=${c.canonicalQueueSaving} pending=${c.canonical?.pending} connected=${c.canonical?.connected} error=${c.error}');
                  expect(find.byType(BusyThinking), findsOneWidget,
                      reason:
                          'A prior terminal receipt cannot hide the new pending assistant; scrolls=${t.stateList<ScrollableState>(find.byType(Scrollable)).map((s) => '${s.position.pixels}/${s.position.maxScrollExtent} viewport=${s.position.viewportDimension}')}');
                  expect(
                      find.byKey(const Key('thinking-loader')), findsOneWidget);
                  expect(find.byKey(const Key('chat-error')), findsNothing);
                  expect(
                      host.requests
                          .where((r) => r['method'] == 'prompt.submit'),
                      hasLength(1));
                  expect(t.takeException(), isNull);
                } finally {
                  gate.complete();
                  for (var i = 0; i < 30; i++) {
                    await t.pump(const Duration(milliseconds: 10));
                    await t.runAsync(() =>
                        Future<void>.delayed(const Duration(milliseconds: 10)));
                    if (!c.busy &&
                        !c.canonicalQueueSaving &&
                        c.canonical!.pending) {
                      break;
                    }
                  }
                  await t.pumpWidget(const SizedBox());
                  await t.runAsync(() async => c.dispose());
                  for (var i = 0; i < 10; i++) {
                    await t.pump(const Duration(milliseconds: 20));
                    await t.runAsync(() =>
                        Future<void>.delayed(const Duration(milliseconds: 20)));
                  }
                }
              }, _RealHttp()));
    }
  }

  for (final explicitPause in [false, true]) {
    testWidgets(
        'foreground retries exhausted read-only recovery; explicit=$explicitPause',
        (t) async {
      final f = FlowFixture()..unavailable = true;
      await f.mount(t);
      f.admission.complete();
      await t.runAsync(() => f.c.send('first'));
      expect(f.c.submit('follower'), isTrue);
      for (var i = 0; i < 3; i++) {
        await t.runAsync(f.c.checkRunStatus);
      }
      expect(f.reads, 4);
      if (explicitPause) f.c.pauseQueue('Paused by you');
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused
      ]) {
        t.binding.handleAppLifecycleStateChanged(state);
      }
      await t.pump();
      f.unavailable = false;
      f.status = 'completed';
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed
      ]) {
        t.binding.handleAppLifecycleStateChanged(state);
      }
      await t.pump(const Duration(seconds: 2));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 10));
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      try {
        expect(f.c.current!.messages.any((m) => m.content == 'Final answer'),
            isTrue,
            reason:
                'Returning online should read the existing receipt without another click');
        expect(f.posts, explicitPause ? 1 : 2);
        if (explicitPause) expect(f.c.queueStatus, 'Paused by you');
      } finally {
        await f.close(t);
      }
    });
  }
}
