import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_home.dart';

import 'prompt_optimizer_acceptance_test.dart' as fixture;

void main() {
  testWidgets('dismissal never sends and the next ordinary tap sends once',
      (tester) async {
    var requests = 0;
    final controller = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response(fixture.response('Answer'), 200);
    });
    controller.sessions.add(controller.current!);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester
        .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
    final composer = find.byKey(const Key('composer'));
    await tester.enterText(composer, 'Send only on a fresh tap');
    await tester.pumpAndSettle();
    final send = find.byTooltip('Send');
    for (final dismissal in ['outside', 'escape', 'back', 'close']) {
      await tester.longPress(send);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Enhance prompt'), findsOneWidget);
      switch (dismissal) {
        case 'outside':
          await tester.tapAt(const Offset(10, 100));
        case 'escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'back':
          await tester.binding.handlePopRoute();
        case 'close':
          await tester.tap(find.byTooltip('Close send actions'));
      }
      await tester.pumpAndSettle();
      expect(find.byTooltip('Enhance prompt'), findsNothing);
      expect(requests, 0);
      expect(controller.outbox, isEmpty);
      expect(tester.widget<TextField>(composer).controller!.text,
          'Send only on a fresh tap');
    }
    await tester.tap(send);
    await fixture.flush(tester);
    expect(requests, 1);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final width in [360.0, 390.0]) {
    for (final keyboard in [0.0, 280.0]) {
      testWidgets(
          '$width 2x keyboard $keyboard long draft slide cannot activate',
          (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var requests = 0;
        final controller = await fixture.controller(MemorySecrets(), (_) async {
          requests++;
          return http.Response(fixture.response('Unused'), 200);
        });
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(2),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: child!,
          ),
          home: ChatHome(controller: controller),
        ));
        final draft = List.generate(24, (i) => 'Long draft line $i').join('\n');
        final composer = find.byKey(const Key('composer'));
        await tester.enterText(composer, draft);
        await tester.pumpAndSettle();
        final send = find.byTooltip('Send');
        final sendRect = tester.getRect(send);
        expect(sendRect.bottom, lessThanOrEqualTo(844 - keyboard));
        for (final destination in ['enhance', 'close', 'outside']) {
          final pointer = await tester.startGesture(tester.getCenter(send));
          await tester.pump(const Duration(milliseconds: 650));
          await tester.pumpAndSettle();
          final enhance = find.byTooltip('Enhance prompt');
          final close = find.byTooltip('Close send actions');
          expect(enhance.hitTestable(), findsOneWidget);
          expect(close.hitTestable(), findsOneWidget);
          expect(tester.getCenter(close), sendRect.center);
          expect(tester.getRect(enhance).top, greaterThanOrEqualTo(0));
          expect(
              tester.getRect(close).bottom, lessThanOrEqualTo(844 - keyboard));
          final end = destination == 'enhance'
              ? tester.getCenter(enhance)
              : destination == 'close'
                  ? tester.getCenter(close)
                  : const Offset(10, 100);
          await pointer.moveTo(end);
          await pointer.up();
          await tester.pumpAndSettle();
          expect(enhance, findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          expect(requests, 0);
          expect(controller.outbox, isEmpty);
          expect(tester.widget<TextField>(composer).controller!.text, draft);
          // A fresh tap is required; release of the opening hold does nothing.
          await tester.tap(close);
          await tester.pumpAndSettle();
          expect(enhance, findsNothing);
        }
        // Movement before the hold wins must not become a tap or send either.
        final drag = await tester.startGesture(tester.getCenter(send));
        await drag.moveBy(const Offset(-80, -80));
        await tester.pump(const Duration(milliseconds: 650));
        await drag.up();
        await tester.pumpAndSettle();
        expect(find.byTooltip('Enhance prompt'), findsNothing);
        expect(requests, 0);
        expect(controller.outbox, isEmpty);
        expect(tester.widget<TextField>(composer).controller!.text, draft);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }

  testWidgets('keyboard and screen reader activate named actions without send',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var requests = 0;
    final controller = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response(fixture.response('Unused'), 200);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester
        .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
    final composer = find.byKey(const Key('composer'));
    await tester.enterText(composer, 'Original draft');
    await tester.pumpAndSettle();
    final send = find.byTooltip('Send');
    final button = find.descendant(of: send, matching: find.byType(IconButton));
    Focus.of(tester.element(button)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    final enhance = find.byTooltip('Enhance prompt');
    final node = tester.getSemantics(enhance);
    expect(node.getSemanticsData().tooltip, 'Enhance prompt');
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    // Focus starts at Enhance, and Enter opens only the review.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await fixture.flush(tester);
    expect(requests, 0);
    await tester.tap(find.text('Keep original'));
    await tester.pumpAndSettle();
    final sendNode = tester.getSemantics(send);
    sendNode.owner!.performAction(sendNode.id, SemanticsAction.customAction,
        sendNode.getSemanticsData().customSemanticsActionIds!.first);
    await tester.pumpAndSettle();
    final actionNode = tester.getSemantics(enhance);
    actionNode.owner!.performAction(actionNode.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await fixture.flush(tester);
    expect(requests, 0);
    await tester.tap(find.text('Keep original'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(button)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(enhance, findsNothing);
    expect(requests, 0);
    expect(controller.outbox, isEmpty);
    expect(
        tester.widget<TextField>(composer).controller!.text, 'Original draft');
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
    controller.dispose();
  });

  testWidgets('removing the Send owner dismisses its modal action group',
      (tester) async {
    final controller = await fixture.controller(MemorySecrets(),
        (_) async => http.Response(fixture.response('Unused'), 200));
    final visible = ValueNotifier(true);
    var replacementTaps = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, show, child) => show
            ? ChatHome(controller: controller)
            : TextButton(
                onPressed: () => replacementTaps++,
                child: const Text('Replacement')),
      ),
    ));
    await tester.enterText(find.byKey(const Key('composer')), 'Keep draft');
    await tester.pumpAndSettle();
    await tester.longPress(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    visible.value = false;
    await tester.pumpAndSettle();
    expect(find.byTooltip('Enhance prompt'), findsNothing);
    expect(find.text('Replacement').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Replacement'));
    expect(replacementTaps, 1);
    await tester.pumpWidget(const SizedBox());
    visible.dispose();
    controller.dispose();
  });
  testWidgets('hold expands Send upward into an anchored icon group',
      (tester) async {
    var requests = 0;
    final controller = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response(fixture.response('Unused'), 200);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester
        .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
    final composer = find.byKey(const Key('composer'));
    await tester.enterText(composer, 'Keep this draft');
    await tester.pumpAndSettle();
    final sendRect = tester.getRect(find.byTooltip('Send'));
    final pointer = await tester.startGesture(sendRect.center);
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<bool>), findsNothing);
    final enhance = find.byTooltip('Enhance prompt');
    final close = find.byTooltip('Close send actions');
    expect(enhance, findsOneWidget);
    expect(close, findsOneWidget);
    expect(find.text('Optimize prompt'), findsNothing);
    expect(tester.getCenter(close), sendRect.center);
    expect(tester.getCenter(enhance).dx, sendRect.center.dx);
    expect(tester.getRect(enhance).bottom, tester.getRect(close).top);
    expect(tester.getSize(enhance).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(enhance).height, greaterThanOrEqualTo(48));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(requests, 0);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(composer).controller!.text, 'Keep this draft');
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
