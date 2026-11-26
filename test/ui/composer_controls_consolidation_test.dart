import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/canonical_controls.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

import '../agent_runs_test.dart' show capabilities;
import '../gateway/hermes_gateway_test.dart' show Fixture, snapshot;
import '../pending_message_home_test.dart' show FlowFixture;
import 'controller_http_test.dart' show makeStore;

void main() {
  for (final width in [360.0, 390.0]) {
    testWidgets(
      'chat-feedback renders structured banners with bounded height at $width 2x + keyboard',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        addTearDown(tester.view.reset);

        final pending = Completer<http.Response>();
        final c = ChatController(
          await makeStore(),
          coreFactory: () => SaathiCore(
            client: MockClient((_) => pending.future),
          ),
        );
        await c.load();
        final connection = {
          'id': 'a',
          'name': 'A',
          'type': 'openai',
          'url': 'https://example.com',
        };
        await c.addConnection(connection, '');
        await c.newSession(connection, 'small', '');
        c.current!.messages.add(
          ChatMessage(role: 'assistant', content: 'Earlier reply'),
        );
        expect(c.submit('In-flight request'), isTrue);
        expect(c.submit('Queued follow-up'), isTrue);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        c.pauseQueue('Queue paused after a temporary issue.');
        c.error = 'Could not reach the server.';

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: ChatHome(controller: c),
          ),
        );
        await tester.pump();

        final feedback = find.byKey(const Key('chat-feedback'));
        expect(feedback, findsOneWidget);
        expect(
          find.text('Queue paused after a temporary issue.'),
          findsOneWidget,
        );
        final feedbackScroll = find
            .descendant(of: feedback, matching: find.byType(Scrollable))
            .first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('chat-error')),
          80,
          scrollable: feedbackScroll,
        );
        await tester.pump();
        expect(find.byKey(const Key('chat-error')), findsOneWidget);

        // Structured Material 3 banner chrome wraps feedback with rounded
        // borders and distinct containers.
        final containers = tester
            .widgetList<Container>(
              find.descendant(of: feedback, matching: find.byType(Container)),
            )
            .where((container) => container.decoration is BoxDecoration)
            .toList();
        expect(containers, isNotEmpty);
        for (final container in containers) {
          final decoration = container.decoration! as BoxDecoration;
          expect(decoration.borderRadius, isNotNull);
          expect(decoration.border, isNotNull);
          expect(decoration.color, isNotNull);
        }

        // Short feedback stays bounded while keeping the composer pinned
        // above the keyboard.
        final shortHeight = tester.getSize(feedback).height;
        expect(shortHeight, lessThanOrEqualTo((844 - 260) * 0.55));
        final send = find.byTooltip('Send');
        expect(send.hitTestable(), findsOneWidget);
        expect(tester.getBottomLeft(send).dy, lessThanOrEqualTo(844 - 260));

        // Long feedback stays bounded and scrollable without crowding out the
        // composer or overflowing.
        c.error = List.filled(80, 'Detailed recovery notice').join(' ');
        await tester.pump();
        final longHeight = tester.getSize(feedback).height;
        expect(longHeight, greaterThanOrEqualTo(shortHeight));
        expect(longHeight, lessThanOrEqualTo((844 - 260) * 0.55));
        expect(send.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
        c.dispose();
        pending.complete(http.Response('{}', 500));
      },
    );
  }

  testWidgets(
    'desktop does not duplicate pendingStatus in both transcript and run bar',
    (tester) async {
      final fixture = FlowFixture()
        ..width = 1280
        ..scale = 1
        ..reduced = true;
      await fixture.mount(tester);

      late Future<bool> sending;
      await tester.runAsync(() async {
        sending = fixture.c.send('hello');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      expect(find.byType(BusyThinking), findsOneWidget);
      expect(find.byKey(const Key('pending-status')), findsOneWidget);
      expect(
        find.text('Sending your message'),
        findsOneWidget,
        reason: 'Sending status must not repeat in both transcript and run bar',
      );

      fixture.admission.complete();
      await tester.runAsync(() => sending);
      await tester.pump();
      expect(find.byType(BusyThinking), findsOneWidget);
      expect(find.byKey(const Key('pending-status')), findsOneWidget);
      expect(
        find.text('Waiting for its turn'),
        findsOneWidget,
        reason: 'Queued status must not repeat in both transcript and run bar',
      );

      fixture.status = 'running';
      await tester.runAsync(() => fixture.c.checkRunStatus());
      await tester.pump();
      expect(find.byType(BusyThinking), findsOneWidget);
      expect(find.byKey(const Key('pending-status')), findsOneWidget);
      expect(
        find.text('Working on your reply'),
        findsOneWidget,
        reason: 'Running status must not repeat in both transcript and run bar',
      );

      // When waiting for a decision, BusyThinking stops and the run bar shows
      // the status exactly once.
      fixture.status = 'stopping';
      await tester.runAsync(() => fixture.c.checkRunStatus());
      await tester.pump();
      expect(find.byType(BusyThinking), findsNothing);
      expect(find.text('Waiting for the server to stop'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await fixture.close(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'Gateway approval humanizes advertised choices, separates action from description, and fails closed',
    (tester) async {
      HttpOverrides.global = null;
      final fixture = Fixture();
      late CanonicalChat chat;
      var choices = <String>['once', 'always', 'deny'];
      Object? command = 'rm -rf /tmp/preview-fixture';
      const description = 'Clean up temporary fixture files';

      await tester.runAsync(() async {
        await fixture.start();
        fixture.respond = (request) {
          if (request['method'] == 'approval.respond') {
            return {'status': 'resolved', 'prompt_id': 'p1'};
          }
          return {
            ...snapshot(),
            'prompts': [
              {
                'kind': 'approval',
                'prompt_id': 'p1',
                'execution_generation': 4,
                'description': description,
                if (command != null) 'command': command,
                'choices': choices,
              },
            ],
          };
        };
        chat = CanonicalChat(
          HermesGatewayClient(grantProvider: () async => fixture.grant()),
          MemorySecrets(),
          source: 'source',
          isCurrent: () => true,
        );
        await chat.connect();
        await chat.attach('chat');
      });

      final composer = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CanonicalComposerControls(
              chat: chat,
              composer: composer,
              queue: (_) => true,
            ),
          ),
        ),
      );

      // 1. Reviewable action with once + always + deny shows human labels,
      // clear button hierarchy, and separates description from action preview.
      await tester.tap(find.text('Review action'));
      await tester.pumpAndSettle();
      expect(find.text('Clean up temporary fixture files'), findsOneWidget);
      expect(find.text('rm -rf /tmp/preview-fixture'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Allow once'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Always allow'),
        findsOneWidget,
      );
      expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);
      expect(find.text('once'), findsNothing);
      expect(find.text('always'), findsNothing);
      expect(find.text('deny'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Allow once'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Always allow'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Deny'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // 2. Backend advertises only ['once', 'deny'] -> 'Always allow' is NOT invented.
      choices = ['once', 'deny'];
      await tester.runAsync(() => chat.attach('chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review action'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Allow once'), findsOneWidget);
      expect(find.text('Always allow'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // 3. Unreviewable affirmative action fails closed while Deny stays enabled.
      choices = ['once', 'always', 'deny'];
      command = null;
      await tester.runAsync(() => chat.attach('chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review action'));
      await tester.pumpAndSettle();
      expect(
        find.text('Action preview unavailable. Approval is disabled.'),
        findsOneWidget,
      );
      expect(find.text('Clean up temporary fixture files'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Allow once'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Always allow'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Deny'))
            .onPressed,
        isNotNull,
      );

      // 4. Selecting 'Deny' sends the exact backend token 'deny'.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Deny'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final approvalCalls = fixture.requests
          .where((r) => r['method'] == 'approval.respond')
          .toList();
      expect(approvalCalls, hasLength(1));
      expect((approvalCalls.single['params'] as Map)['choice'], 'deny');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      composer.dispose();
      await tester.runAsync(() async {
        await chat.close();
        await fixture.close();
      });
    },
  );

  testWidgets(
    'HTTP Runs Guide and Stop controls render clear labels and tooltips at 360px 2x + keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.reset);

      final controlRequests = <String>[];
      SharedPreferences.setMockInitialValues({});
      final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets(),
      );
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          return http.Response(
            jsonEncode({
              'features': {
                ...capabilities['features'] as Map,
                'run_steer': true,
                'run_stop': true,
              },
              'endpoints': {
                ...capabilities['endpoints'] as Map,
                'run_steer': {
                  'method': 'POST',
                  'path': '/v1/runs/{run_id}/steer',
                },
                'run_stop': {
                  'method': 'POST',
                  'path': '/v1/runs/{run_id}/stop',
                },
              },
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == '/v1/runs') {
          return http.Response(
            jsonEncode({
              'run_id': 'run_busy',
              'status': 'running',
              'admission_id': 'adm_busy',
              'execution_generation': 1,
            }),
            202,
          );
        }
        if (request.method == 'POST' &&
            (request.url.path.endsWith('/steer') ||
                request.url.path.endsWith('/stop'))) {
          controlRequests.add(request.url.path);
          return http.Response(
            jsonEncode({
              'run_id': 'run_busy',
              'status':
                  request.url.path.endsWith('/stop') ? 'stopping' : 'running',
              'admission_id': 'adm_busy',
              'execution_generation': 1,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'run_id': 'run_busy',
            'status': 'running',
            'admission_id': 'adm_busy',
            'execution_generation': 1,
          }),
          200,
        );
      });

      final c = ChatController(
        store,
        runClientFactory: (root, key) => RunClient(root, key, client: client),
      );
      await c.load();
      await c.addConnection({
        'id': 'hermes',
        'name': 'Hermes',
        'type': 'hermes',
        'url': 'https://hermes.example',
      }, 'fixture');
      await c.newSession(c.connections.single, 'model', '');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: ChatHome(controller: c),
        ),
      );

      await tester.runAsync(() => c.send('Start work'));
      await tester.pump();

      // Guide and Stop have visible labels and keep their tooltips.
      final guideTooltip = find.byTooltip('Guide current work');
      final stopTooltip = find.byTooltip('Stop current work');
      expect(guideTooltip.hitTestable(), findsOneWidget);
      expect(stopTooltip.hitTestable(), findsOneWidget);
      expect(find.text('Guide'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);

      // Guide is disabled while draft is empty, enabled once draft is entered.
      await tester.enterText(
          find.byKey(const Key('composer')), 'Focus on tests');
      await tester.pump();
      await tester.tap(guideTooltip);
      for (var i = 0; i < 6 && c.controlBusy; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump();
      expect(controlRequests, ['/v1/runs/run_busy/steer']);

      // Stop stays distinct and works on tap.
      expect(stopTooltip.hitTestable(), findsOneWidget);
      await tester.tap(stopTooltip);
      for (var i = 0; i < 6 && c.controlBusy; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pump();
      expect(controlRequests, [
        '/v1/runs/run_busy/steer',
        '/v1/runs/run_busy/stop',
      ]);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
