import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/growing_message_input.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../prompt_optimizer_acceptance_test.dart' as optimizer_fixture;

Future<ChatController> _makeTwoChatController({
  Future<http.Response> Function(http.Request)? onRequest,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = SaathiStore(
    preferences: await SharedPreferences.getInstance(),
    secrets: MemorySecrets(),
  );
  final client = MockClient(
    onRequest ??
        (_) async => http.Response(
              '{"choices":[{"message":{"content":"Answer"}}]}',
              200,
            ),
  );
  final controller = ChatController(
    store,
    coreFactory: () => SaathiCore(client: client),
  );
  await controller.load();
  final connection = {
    'id': 'direct',
    'name': 'Direct',
    'type': 'openai',
    'url': 'https://example.com',
  };
  await controller.addConnection(connection, 'fixture-key');
  await controller.newSession(connection, 'model-a', '');
  await controller.newSession(connection, 'model-b', '');
  return controller;
}

void main() {
  group('Per-conversation draft preservation and isolation', () {
    testWidgets(
      'preserves isolated drafts across switches and notification navigation',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final controller = await _makeTwoChatController();
        final sessionA = controller.sessions[0];
        final sessionB = controller.sessions[1];
        expect(controller.current, same(sessionB));

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(home: ChatHome(controller: controller)),
        );
        await tester.pumpAndSettle();

        final composer = find.byKey(const Key('composer'));
        String composerText() =>
            tester.widget<TextField>(composer).controller!.text;

        await tester.enterText(composer, 'Draft for B');
        await tester.pump();
        expect(composerText(), 'Draft for B');

        // Switching to A via sidebar must not leak B's draft.
        await tester.tap(find.text('On this device · model-a'));
        await tester.pumpAndSettle();
        expect(controller.current, same(sessionA));
        expect(composerText(), isEmpty);

        await tester.enterText(composer, 'Draft for A');
        await tester.pump();

        // Switching back to B restores B's draft with collapsed selection at end.
        await tester.tap(find.text('On this device · model-b'));
        await tester.pumpAndSettle();
        expect(controller.current, same(sessionB));
        expect(composerText(), 'Draft for B');
        expect(
          tester.widget<TextField>(composer).controller!.selection,
          const TextSelection.collapsed(offset: 'Draft for B'.length),
        );

        // Notification navigation to same conversation keeps its draft.
        expect(controller.openNotificationConversation(sessionB.id), isTrue);
        await tester.pump();
        expect(composerText(), 'Draft for B');

        // Notification navigation to A restores A's draft without leaking B's.
        expect(controller.openNotificationConversation(sessionA.id), isTrue);
        await tester.pump();
        expect(controller.current, same(sessionA));
        expect(composerText(), 'Draft for A');

        // Notification navigation back to B restores B's draft.
        expect(controller.openNotificationConversation(sessionB.id), isTrue);
        await tester.pump();
        expect(controller.current, same(sessionB));
        expect(composerText(), 'Draft for B');

        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );

    testWidgets(
      'backing out of NewChatPage preserves active draft; deleting clears it',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final controller = await _makeTwoChatController();
        final original = controller.current!;
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(home: ChatHome(controller: controller)),
        );
        await tester.pumpAndSettle();

        final composer = find.byKey(const Key('composer'));
        await tester.enterText(composer, 'Keep across cancelled NewChat');
        await tester.pump();

        await tester.tap(find.byTooltip('New conversation'));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(controller.current, same(original));
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'Keep across cancelled NewChat',
        );

        // Deleting the active conversation removes its saved draft.
        await tester.tap(find.byTooltip('Delete conversation'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(controller.current, isNull);
        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );

    testWidgets(
      'swapping ChatController clears cached drafts for strict A07 isolation',
      (tester) async {
        final first = await _makeTwoChatController();
        final second = await _makeTwoChatController();
        // Force identical conversation identity across distinct controllers.
        final sharedId = first.current!.id;
        final matching = ChatSession(
          id: sharedId,
          connectionId: first.current!.connectionId,
          model: 'model-b',
        );
        second.sessions.add(matching);
        second.select(matching);

        final activeController = ValueNotifier<ChatController>(first);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(
            home: ValueListenableBuilder<ChatController>(
              valueListenable: activeController,
              builder: (_, controller, __) => ChatHome(controller: controller),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final composer = find.byKey(const Key('composer'));
        await tester.enterText(composer, 'Private to first controller');
        await tester.pump();

        activeController.value = second;
        await tester.pumpAndSettle();

        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

        await tester.pumpWidget(const SizedBox());
        activeController.dispose();
        first.dispose();
        second.dispose();
      },
    );
  });

  group('GrowingMessageInput desktop keyboard shortcuts', () {
    testWidgets(
      'Enter submits, Shift+Enter and IME composition do not, repeat does not insert newlines',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        var submits = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GrowingMessageInput(
                controller: controller,
                enabled: true,
                onChanged: (_) {},
                onSubmit: () => submits++,
              ),
            ),
          ),
        );

        final composer = find.byKey(const Key('composer'));
        await tester.tap(composer);
        await tester.pump();

        // Empty / whitespace draft does not submit and does not add newlines.
        await tester.enterText(composer, '   ');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(submits, 0);
        expect(controller.text, '   ');

        // Enter submits non-empty draft once.
        await tester.enterText(composer, 'Hello desktop');
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(submits, 1);

        // Held KeyRepeatEvent does not double-submit or insert stray newlines.
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(submits, 1);
        expect(controller.text, 'Hello desktop');
        expect(controller.text.contains('\n'), isFalse);

        // Shift+Enter does not submit.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(submits, 1);

        // Alt+Enter does not submit.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        expect(submits, 1);

        // IME composition active: Enter must not submit.
        controller.value = const TextEditingValue(
          text: 'nihao',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(submits, 1);

        // Once composition commits, Enter submits again (and numpadEnter on platforms with keycodes).
        controller.value = const TextEditingValue(
          text: '你好',
          selection: TextSelection.collapsed(offset: 2),
        );
        await tester.pump();
        final submitKey =
            debugDefaultTargetPlatformOverride == TargetPlatform.windows
                ? LogicalKeyboardKey.enter
                : LogicalKeyboardKey.numpadEnter;
        await tester.sendKeyEvent(submitKey);
        await tester.pump();
        expect(submits, 2);
      },
      variant: TargetPlatformVariant.desktop(),
    );

    testWidgets(
      'mobile platforms ignore Enter key events',
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        var submits = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GrowingMessageInput(
                controller: controller,
                enabled: true,
                onChanged: (_) {},
                onSubmit: () => submits++,
              ),
            ),
          ),
        );

        final composer = find.byKey(const Key('composer'));
        await tester.enterText(composer, 'Mobile draft');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(submits, 0);
      },
      variant: TargetPlatformVariant.mobile(),
    );
  });

  group('Desktop ChatHome shortcuts and Send tooltip safety', () {
    testWidgets(
      'long-press opens Enhance prompt, Tooltip stays manual with hover, and Enter sends and clears saved draft',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        var requests = 0;
        final controller = await _makeTwoChatController(
          onRequest: (_) async {
            requests++;
            return http.Response(
              optimizer_fixture.response('Desktop answer'),
              200,
            );
          },
        );
        final sessionA = controller.sessions[0];
        final sessionB = controller.sessions[1];
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(home: ChatHome(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Send Tooltip keeps manual triggerMode on desktop so long-press is never stolen.
        final sendTooltipFinder = find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == 'Send',
        );
        expect(sendTooltipFinder, findsOneWidget);
        expect(
          tester.widget<Tooltip>(sendTooltipFinder).triggerMode,
          TooltipTriggerMode.manual,
        );

        // Hovering Send shows the tooltip via MouseRegion and exiting dismisses it.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await tester.pump();
        await mouse.moveTo(tester.getCenter(sendTooltipFinder));
        await tester.pump();
        expect(find.text('Send'), findsOneWidget);
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(find.text('Send'), findsNothing);

        final composer = find.byKey(const Key('composer'));
        await tester.enterText(composer, 'Desktop draft to send');
        await tester.pumpAndSettle();

        // Long-press on Send still opens Enhance prompt without sending.
        await tester.longPress(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Enhance prompt'), findsOneWidget);
        expect(requests, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Enhance prompt'), findsNothing);
        expect(requests, 0);

        // Focus composer and press Enter to send and clear saved draft.
        await tester.tap(composer);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await optimizer_fixture.flush(tester);

        expect(requests, 1);
        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

        // Switching to A and back to B must not resurrect the sent draft.
        await tester.tap(find.text('On this device · model-a'));
        await tester.pumpAndSettle();
        expect(controller.current, same(sessionA));
        await tester.tap(find.text('On this device · model-b'));
        await tester.pumpAndSettle();
        expect(controller.current, same(sessionB));
        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  });
}
