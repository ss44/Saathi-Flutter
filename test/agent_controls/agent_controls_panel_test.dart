import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_controls/agent_controls.dart';
import 'package:saathi/agent_controls/agent_controls_panel.dart';
import 'agent_controls_test.dart' show approval, run;

void main() {
  for (final scenario in [
    (
      name: 'fully redacted callback',
      command: 'echo hello',
      redact: true,
      allowed: false
    ),
    (
      name: 'credential-only command',
      command: 'sk-abcdefghijk',
      redact: false,
      allowed: false
    ),
    (
      name: 'partially redacted command',
      command: 'echo sk-abcdefghijk',
      redact: false,
      allowed: true
    ),
    (
      name: 'invisible-only command',
      command: '\u0000\u0007\u200b\u200e\u2060\u202e\u00ad',
      redact: false,
      allowed: false
    ),
    (
      name: 'invisible-only preview',
      command: 'echo hello',
      redact: true,
      allowed: false
    ),
    (
      name: 'international command',
      command: '打印 नमस्ते مرحبا',
      redact: false,
      allowed: true
    ),
  ]) {
    testWidgets('approval visibility: ${scenario.name}', (tester) async {
      final scope =
          ControlScope(sourceId: 's', runId: 'r', authorityToken: Object());
      final c = AgentControlsController(ControlBoundary(
        scope: scope,
        isCurrentAuthority: (_) => true,
        supportsAction: (_) => true,
        refresh: () async => PendingControlsSnapshot.fromJson(
            scope,
            run([
              {...approval(), 'command': scenario.command}
            ])),
        postDecision: (_, body) async => const ControlPostResult(409, {}),
      ));
      await c.refresh();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AgentControlsPanel(
        controller: c,
        redact: scenario.redact
            ? (_) => scenario.name == 'invisible-only preview'
                ? '\u0000\u0007\u200b\u200e\u2060\u202e\u00ad'
                : '[redacted]'
            : null,
      ))));
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Allow once'))
              .onPressed,
          scenario.allowed ? isNotNull : isNull);
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'Deny'))
              .onPressed,
          isNotNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
  testWidgets('failed redaction and raw JSON cannot enable blind approval',
      (tester) async {
    final scope =
        ControlScope(sourceId: 's', runId: 'r', authorityToken: Object());
    for (final command in ['echo hello', '{"tool":"private payload"}']) {
      final c = AgentControlsController(ControlBoundary(
        scope: scope,
        isCurrentAuthority: (_) => true,
        supportsAction: (_) => true,
        refresh: () async => PendingControlsSnapshot.fromJson(
            scope,
            run([
              {...approval(), 'command': command}
            ])),
        postDecision: (action, body) async => const ControlPostResult(409, {}),
      ));
      await c.refresh();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AgentControlsPanel(
                  controller: c,
                  redact: (s) {
                    if (command == 'echo hello') throw StateError('secret');
                    return s;
                  }))));
      final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Allow once'));
      expect(button.onPressed, isNull);
      expect(find.textContaining('private payload'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });
  testWidgets('free answer stays local until explicit Send', (tester) async {
    final scope =
        ControlScope(sourceId: 's', runId: 'r', authorityToken: Object());
    final posts = <Map<String, Object?>>[];
    final c = AgentControlsController(ControlBoundary(
      scope: scope,
      isCurrentAuthority: (_) => true,
      supportsAction: (_) => true,
      refresh: () async => PendingControlsSnapshot.fromJson(
          scope,
          run([
            {
              'kind': 'clarify',
              'prompt_id': 'q',
              'execution_generation': 3,
              'question': 'Where?',
              'choices': []
            }
          ])),
      postDecision: (action, body) async {
        posts.add(body);
        return const ControlPostResult(409, {});
      },
    ));
    await c.refresh();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AgentControlsPanel(controller: c))));
    await tester.enterText(find.byType(TextField), 'a destination');
    await tester.pump();
    expect(posts, isEmpty);
    await tester.ensureVisible(find.text('Send'));
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(posts.single, {
      'request_id': 'q',
      'execution_generation': 3,
      'answer': 'a destination'
    });
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('only returned approval choices are rendered', (tester) async {
    final scope =
        ControlScope(sourceId: 's', runId: 'r', authorityToken: Object());
    final c = AgentControlsController(ControlBoundary(
      scope: scope,
      isCurrentAuthority: (_) => true,
      supportsAction: (_) => true,
      refresh: () async => PendingControlsSnapshot.fromJson(
          scope,
          run([
            {
              ...approval(),
              'choices': ['deny'],
              'privateReasoning': 'hidden reasoning',
              'tool': {'raw': 'tool JSON'}
            }
          ])),
      postDecision: (action, body) async => const ControlPostResult(409, {}),
    ));
    await c.refresh();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AgentControlsPanel(controller: c))));
    expect(find.text('Allow once'), findsNothing);
    expect(find.text('Deny'), findsOneWidget);
    expect(find.textContaining('hidden reasoning'), findsNothing);
    expect(find.textContaining('tool JSON'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  for (final width in [390.0, 360.0]) {
    testWidgets('wraps at $width with keyboard and redacts previews',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scope =
          ControlScope(sourceId: 's', runId: 'r', authorityToken: Object());
      final c = AgentControlsController(ControlBoundary(
        scope: scope,
        isCurrentAuthority: (_) => true,
        supportsAction: (_) => true,
        refresh: () async => PendingControlsSnapshot.fromJson(
            scope,
            run([
              {
                ...approval(),
                'command':
                    'echo API_KEY=supersecret privatevalue ${'word ' * 60}'
              },
              {
                'kind': 'clarify',
                'prompt_id': 'q',
                'execution_generation': 3,
                'question': 'Which destination should be used? ${'word ' * 50}',
                'choices': ['A long choice with several words', 'Other']
              },
            ])),
        postDecision: (action, body) async => const ControlPostResult(409, {}),
      ));
      await c.refresh();
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
        data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(width == 360 ? 2 : 1),
            viewInsets: const EdgeInsets.only(bottom: 280)),
        child: Scaffold(
            body: AgentControlsPanel(
                controller: c,
                redact: (s) => s.replaceAll('privatevalue', '[redacted]'))),
      )));
      expect(find.text('Allow once'), findsOneWidget);
      expect(find.text('Deny'), findsOneWidget);
      expect(find.text('Always'), findsNothing);
      expect(find.textContaining('supersecret'), findsNothing);
      expect(find.textContaining('privatevalue'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
  testWidgets('clarification choice requires explicit Send', (tester) async {
    final scope =
        ControlScope(sourceId: 's', runId: 'r', authorityToken: Object());
    var posts = 0;
    final c = AgentControlsController(ControlBoundary(
      scope: scope,
      isCurrentAuthority: (_) => true,
      supportsAction: (_) => true,
      refresh: () async => PendingControlsSnapshot.fromJson(
          scope,
          run([
            {
              'kind': 'clarify',
              'prompt_id': 'q',
              'execution_generation': 3,
              'question': 'Where?',
              'choices': ['A', 'B']
            }
          ])),
      postDecision: (_, body) async {
        posts++;
        expect(body,
            {'request_id': 'q', 'execution_generation': 3, 'answer': 'B'});
        return const ControlPostResult(409, {});
      },
    ));
    await c.refresh();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AgentControlsPanel(controller: c))));
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(posts, 0);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(posts, 1);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
