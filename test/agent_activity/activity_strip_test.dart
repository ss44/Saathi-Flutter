import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_activity/activity_model.dart';
import 'package:saathi/agent_activity/activity_strip.dart';

void main() {
  testWidgets('answer needed and capacity overflow are visible',
      (tester) async {
    final m = ActivityModel(redact: (s) => s, maxParents: 1, maxChildren: 1);
    addTearDown(m.dispose);
    final b = m.bind(
        connectionId: 'a',
        revision: '1',
        connectionName: 'Home',
        localChatId: 'chat',
        runId: 'run',
        title: 'Title');
    m.updateStatus(b, ActivityStatus.answerNeeded);
    m.bind(
        connectionId: 'b',
        revision: '1',
        connectionName: 'Work',
        localChatId: 'other',
        runId: 'other',
        title: 'Other');
    for (var i = 1; i <= 2; i++) {
      m.event(b, {
        'event': 'subagent.start',
        'run_id': 'run',
        'seq': i,
        'subagent_id': 'child$i'
      });
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AgentActivityStrip(
                model: m,
                onOpenParent: (_) {},
                onOpenChildHistory: (_, child) {}))));
    expect(find.text('Needs your attention'), findsOneWidget);
    await tester.tap(find.text('Needs your attention'));
    await tester.pumpAndSettle();
    expect(find.text('Answer needed'), findsOneWidget);
    expect(find.text('More active tasks not shown · retention limit reached'),
        findsOneWidget);
    expect(
        find.text(
            'More active child tasks not shown · retention limit reached'),
        findsOneWidget);
  });
  for (final width in [390.0, 360.0]) {
    testWidgets(
        'strip above composer opens grouped panel and real callbacks $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = ActivityModel(redact: (s) => s);
      addTearDown(model.dispose);
      final a = model.bind(
          connectionId: 'a',
          revision: '1',
          connectionName: 'Home server',
          localChatId: 'chat-a',
          runId: 'run',
          title: 'Plan trip');
      final b = model.bind(
          connectionId: 'b',
          revision: '1',
          connectionName: 'Work server',
          localChatId: 'chat-b',
          runId: 'run',
          title: 'Review code');
      model.updateStatus(a, ActivityStatus.waitingApproval);
      model.updateStatus(b, ActivityStatus.running);
      model.event(a, {
        'event': 'subagent.start',
        'run_id': 'run',
        'seq': 1,
        'subagent_id': 'child',
        'child_session_id': 'history',
        'goal': 'Check routes'
      });
      model.event(b, {
        'event': 'subagent.start',
        'run_id': 'run',
        'seq': 1,
        'subagent_id': 'child',
        'goal': 'Check code'
      });
      ActivityBinding? opened;
      String? history;
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(
                  size: Size(width, 844),
                  textScaler: TextScaler.linear(width == 360 ? 2 : 1),
                  viewInsets: const EdgeInsets.only(bottom: 300)),
              child: Scaffold(
                  body: Column(children: [
                const Expanded(child: SizedBox()),
                AgentActivityStrip(
                    model: model,
                    onOpenParent: (b) => opened = b,
                    onOpenChildHistory: (b, c) {
                      opened = b;
                      history = c.childSessionId;
                    }),
                const TextField(key: Key('composer'))
              ])))));
      expect(
          tester.getBottomLeft(find.byType(AgentActivityStrip)).dy,
          lessThanOrEqualTo(
              tester.getTopLeft(find.byKey(const Key('composer'))).dy));
      expect(find.text('Needs your attention'), findsOneWidget);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      expect(find.text('Home server'), findsOneWidget);
      expect(find.text('Work server'), findsOneWidget);
      expect(find.textContaining('History unavailable'), findsOneWidget);
      await tester.tap(find.text('Check routes'));
      await tester.pumpAndSettle();
      expect(identical(opened, a), isTrue);
      expect(history, 'history');
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plan trip'));
      await tester.pumpAndSettle();
      expect(identical(opened, a), isTrue);
      expect(tester.takeException(), isNull);
      // A native Material button is focusable and keyboard activatable.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Agent activity'), findsOneWidget);
      model.removeConnection('a');
      model.removeConnection('b');
      await tester.pumpAndSettle();
      expect(find.byType(OutlinedButton), findsNothing);
    });
  }
  testWidgets('idle and unsupported have no strip', (tester) async {
    for (final supported in [true, false]) {
      final model = ActivityModel(redact: (s) => s, supported: supported);
      if (!supported) {
        model.bind(
            connectionId: 'a',
            revision: '1',
            connectionName: 'A',
            localChatId: 'c',
            runId: 'r',
            title: 'T');
      }
      await tester.pumpWidget(MaterialApp(
          home: AgentActivityStrip(
              model: model,
              onOpenParent: (_) {},
              onOpenChildHistory: (_, __) {})));
      expect(find.byType(OutlinedButton), findsNothing);
      model.dispose();
    }
  });
}
