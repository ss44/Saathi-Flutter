import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'controller_http_test.dart' show makeStore;

// Promoted from the preserved independent probe. Only the import, formatting
// and diagnostic printer are normalized; its behavioral assertions stay intact.
void main() {
  for (final variable in [false, true]) {
    testWidgets('independent latest variable=$variable', (t) async {
      final c = ChatController(await makeStore());
      await c.load();
      final connection = {
        'id': 'a',
        'name': 'A',
        'type': 'openai',
        'url': 'https://example.com'
      };
      await c.addConnection(connection, '');
      await c.newSession(connection, 'small', '');
      c.current!.messages.addAll(List.generate(
          60,
          (i) => ChatMessage(
              role: 'model',
              content: variable && i >= 30
                  ? 'Long answer paragraph.\n\n' * 30
                  : 'History row $i')));
      await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
      await t.pumpAndSettle();
      final scroll =
          t.widget<ListView>(find.byType(ListView).first).controller!;
      final input = find.byKey(const Key('composer'));
      await t.enterText(input, 'Keep draft');
      await t.pumpAndSettle();
      final editable = t.widget<EditableText>(
          find.descendant(of: input, matching: find.byType(EditableText)));
      expect(editable.focusNode.hasFocus, isTrue);
      await t.tap(find.byTooltip('Jump to latest'),
          kind: variable ? PointerDeviceKind.touch : PointerDeviceKind.mouse);
      await t.pumpAndSettle();
      final remaining = scroll.position.extentAfter;
      final focused = editable.focusNode.hasFocus;
      await t.pumpWidget(const SizedBox());
      c.dispose();
      expect(remaining, lessThanOrEqualTo(1));
      expect(focused, isTrue);
    });
  }

  for (final cancellation in [
    'wheel',
    'touch down',
    'trackpad start',
    'selection round trip',
    'source replacement',
    'controller replacement',
    'dispose',
  ]) {
    testWidgets('pending lazy jump cancelled by $cancellation', (t) async {
      final c = await variedChat();
      await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
      await t.pumpAndSettle();
      final list = find.byType(ListView).first;
      final scroll = t.widget<ListView>(list).controller!;
      await t.tap(find.byTooltip('Jump to latest'));
      // Revoke after the estimated jump, before layout discovers the true edge.
      // This fixture needs only one correction, so pumping here is too late.
      final jumped = scroll.offset;
      TestGesture? gesture;
      ChatController? replacement;
      switch (cancellation) {
        case 'wheel':
          await t.sendEventToBinding(PointerScrollEvent(
              position: t.getCenter(list),
              scrollDelta: const Offset(0, -300),
              kind: PointerDeviceKind.mouse));
        case 'touch down':
          gesture = await t.startGesture(t.getCenter(list));
        case 'trackpad start':
          gesture = await t.createGesture(kind: PointerDeviceKind.trackpad);
          await gesture.panZoomStart(t.getCenter(list));
        case 'selection round trip':
          final original = c.current!;
          final other = ChatSession(
              id: 'other', connectionId: original.connectionId, model: 'small');
          c.sessions.add(other);
          c.select(other);
          c.select(original);
          // Selection remounts the transcript and establishes a new position.
          await t.pump();
        case 'source replacement':
          c.connections[0] = Map<String, dynamic>.of(c.connections.first);
        case 'controller replacement':
          replacement = await variedChat();
          await t
              .pumpWidget(MaterialApp(home: ChatHome(controller: replacement)));
        case 'dispose':
          await t.pumpWidget(const SizedBox());
      }
      if (cancellation != 'dispose') {
        final readerOffset = scroll.offset;
        if (cancellation == 'wheel') expect(readerOffset, lessThan(jumped));
        await t.pumpAndSettle();
        expect(scroll.offset, readerOffset,
            reason: 'A revoked correction must not move the reader');
        expect(scroll.position.extentAfter, greaterThan(1));
      }
      if (cancellation == 'trackpad start') {
        await gesture!.panZoomEnd();
      } else {
        await gesture?.up();
      }
      await t.pumpWidget(const SizedBox());
      await t.pump();
      expect(t.takeException(), isNull);
      c.dispose();
      replacement?.dispose();
    });
  }

  testWidgets('keyboard traversal and activation do not refocus the draft',
      (t) async {
    final c = await variedChat();
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    final input = find.byKey(const Key('composer'));
    await t.enterText(input, 'Keep draft');
    await t.pumpAndSettle();
    final editable = t.widget<EditableText>(
        find.descendant(of: input, matching: find.byType(EditableText)));
    final buttonFocus =
        Focus.of(t.element(find.byIcon(Icons.keyboard_arrow_down_rounded)));
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < 12 && !buttonFocus.hasFocus; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
    }
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(buttonFocus.hasFocus, isTrue);
    expect(editable.focusNode.hasFocus, isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(editable.focusNode.hasFocus, isFalse);
    await t.pumpAndSettle();
    final scroll = t.widget<ListView>(find.byType(ListView).first).controller!;
    expect(scroll.position.extentAfter, lessThanOrEqualTo(1));
    expect(t.widget<TextField>(input).controller!.text, 'Keep draft');
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}

Future<ChatController> variedChat() async {
  final c = ChatController(await makeStore());
  await c.load();
  final connection = {
    'id': 'a',
    'name': 'A',
    'type': 'openai',
    'url': 'https://example.com'
  };
  await c.addConnection(connection, '');
  await c.newSession(connection, 'small', '');
  c.current!.messages.addAll(List.generate(
      60,
      (i) => ChatMessage(
          role: 'model',
          content:
              i >= 30 ? 'Long answer paragraph.\n\n' * 30 : 'History row $i')));
  return c;
}
