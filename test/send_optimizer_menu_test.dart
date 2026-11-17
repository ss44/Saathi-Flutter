import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_home.dart';
import 'prompt_optimizer_acceptance_test.dart' as fixture;

void main() {
  testWidgets('holding busy Send never queues or clears a draft',
      (tester) async {
    final c = await fixture.controller(MemorySecrets(),
        (_) async => http.Response(fixture.response('Unused'), 200));
    c.sessions.add(c.current!);
    c.busy = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    final composer = find.byKey(const Key('composer'));
    await tester.enterText(composer, 'Do not queue');
    await tester.pump();
    await tester.longPress(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, 'Do not queue');
    expect(c.outbox, isEmpty);
    expect(find.byTooltip('Enhance prompt'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('ChatHome retains Apply and Undo owner across keyboard changes',
      (tester) async {
    var requests = 0;
    final c = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response(fixture.response('Improved'), 200);
    });
    final keyboard = ValueNotifier(0.0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => ValueListenableBuilder<double>(
            valueListenable: keyboard,
            builder: (_, inset, unused) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(viewInsets: EdgeInsets.only(bottom: inset)),
                child: child!)),
        home: ChatHome(controller: c)));
    final composer = find.byKey(const Key('composer'));
    await tester.enterText(composer, 'Original');
    await tester.pump();
    await tester.longPress(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Enhance prompt'));
    await tester.pumpAndSettle();
    await fixture.improve(tester);
    await fixture.flush(tester);
    keyboard.value = 280;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, 'Improved');
    expect(requests, 1);
    expect(c.current!.messages, hasLength(1));
    keyboard.value = 0;
    await tester.pumpAndSettle();
    final sendRect = tester.getRect(find.byTooltip('Send'));
    await tester.longPress(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    // Undo below Send must not become part of the action group's anchor.
    expect(tester.getCenter(find.byTooltip('Close send actions')),
        sendRect.center);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(tester.widget<TextField>(composer).controller!.text, 'Original');
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox());
    keyboard.dispose();
    c.dispose();
  });
  testWidgets('ChatHome unsupported agent has explanation and no inference',
      (tester) async {
    var requests = 0;
    final c = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response(fixture.response('Improved'), 200);
    });
    c.connections[0]['type'] = 'hermes';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.enterText(find.byKey(const Key('composer')), 'Original');
    await tester.pump();
    await tester.longPress(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Enhance prompt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No direct text connection'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.ancestor(
                of: find.text('Improve'), matching: find.byType(FilledButton)))
            .onPressed,
        isNull);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('ordinary Send tap dispatches exactly once without optimizer',
      (tester) async {
    var requests = 0;
    final c = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response(fixture.response('Answer'), 200);
    });
    c.sessions.add(c.current!);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.enterText(find.byKey(const Key('composer')), 'Send me');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await fixture.flush(tester);
    expect(requests, 1);
    expect(find.byTooltip('Enhance prompt'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text,
        isEmpty);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Send keyboard and semantics expose menu without sending',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var requests = 0;
    final c = await fixture.controller(MemorySecrets(), (_) async {
      requests++;
      return http.Response(fixture.response('Improved'), 200);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.enterText(find.byKey(const Key('composer')), 'Original');
    await tester.pumpAndSettle();
    final send = find.byTooltip('Send');
    final node = tester.getSemantics(send);
    expect(
        node.getSemanticsData().hasAction(SemanticsAction.longPress), isTrue);
    expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty);
    node.owner!.performAction(node.id, SemanticsAction.customAction,
        node.getSemanticsData().customSemanticsActionIds!.first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Enhance prompt'), findsOneWidget);
    expect(requests, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final button = find.descendant(of: send, matching: find.byType(IconButton));
    Focus.of(tester.element(button)).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Enhance prompt'), findsOneWidget);
    expect(requests, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(send, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Enhance prompt'), findsOneWidget);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
    c.dispose();
  });
  for (final change in [
    'draft',
    'session',
    'session round trip',
    'source',
    'lifecycle',
    'busy',
    'read only',
    'controller dispose',
    'owner'
  ]) {
    testWidgets('$change revokes stale Send menu', (tester) async {
      var requests = 0;
      final c = await fixture.controller(MemorySecrets(), (_) async {
        requests++;
        return http.Response(fixture.response('Improved'), 200);
      });
      final visible = ValueNotifier(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MaterialApp(
          home: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, show, child) =>
                  show ? ChatHome(controller: c) : const SizedBox())));
      await tester.enterText(find.byKey(const Key('composer')), 'Original');
      await tester.pumpAndSettle();
      await tester.longPress(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Enhance prompt'), findsOneWidget);
      if (change == 'draft') {
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text = 'Newer';
      } else if (change.startsWith('session')) {
        final previous = c.current;
        c.current =
            ChatSession(id: 'new', connectionId: 'direct', model: 'test');
        c.notifyListeners();
        if (change == 'session round trip') c.current = previous;
      } else if (change == 'source') {
        c.connections[0] = {...c.connections[0]};
      } else if (change == 'lifecycle') {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      } else if (change == 'busy') {
        c.busy = true;
      } else if (change == 'read only') {
        c.connections.clear();
      } else if (change == 'controller dispose') {
        c.dispose();
      } else {
        visible.value = false;
      }
      c.notifyListeners();
      await tester.pumpAndSettle();
      if (change == 'session' || change == 'owner') {
        // The anchored control was disposed; its route must leave with it.
        expect(find.byTooltip('Enhance prompt'), findsNothing);
      } else {
        await tester.tap(find.byTooltip('Enhance prompt'));
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(requests, 0);
      await tester.pumpWidget(const SizedBox());
      visible.dispose();
      if (change != 'controller dispose') c.dispose();
    });
  }
  for (final width in [360.0, 390.0]) {
    for (final keyboard in [0.0, 280.0]) {
      testWidgets('$width keyboard $keyboard hold Send only opens menu',
          (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var requests = 0;
        final c = await fixture.controller(MemorySecrets(), (_) async {
          requests++;
          return http.Response(fixture.response('Improved'), 200);
        });
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(2),
                    viewInsets: EdgeInsets.only(bottom: keyboard)),
                child: child!),
            home: ChatHome(controller: c)));
        await tester.enterText(find.byKey(const Key('composer')), 'Original');
        await tester.pumpAndSettle();
        expect(find.byTooltip('Improve prompt'), findsNothing);
        expect(find.byIcon(Icons.auto_fix_high_outlined), findsNothing);
        final send = find.byTooltip('Send');
        final pointer = await tester.startGesture(tester.getCenter(send));
        await tester.pump(const Duration(milliseconds: 650));
        expect(find.byTooltip('Enhance prompt'), findsOneWidget);
        await pointer.up();
        await tester.pumpAndSettle();
        expect(requests, 0);
        expect(
            tester
                .widget<TextField>(find.byKey(const Key('composer')))
                .controller!
                .text,
            'Original');
        await tester.tapAt(const Offset(10, 100));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(requests, 0);
        await tester.longPress(send);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Enhance prompt'));
        await tester.pumpAndSettle();
        expect(find.text('Original'), findsWidgets);
        expect(requests, 0);
        await fixture.improve(tester);
        await fixture.flush(tester);
        expect(requests, 1);
        expect(find.text('Apply'), findsOneWidget);
        expect(c.current!.messages, hasLength(1));
        await tester.tap(find.text('Keep original'));
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<TextField>(find.byKey(const Key('composer')))
                .controller!
                .text,
            'Original');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      });
    }
  }
}
