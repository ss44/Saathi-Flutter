import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/transcript_latest.dart';

import 'jump_latest_regression_test.dart' show variedChat;

void main() {
  for (final cancellation in [
    'source restored',
    'source round trip',
    'wheel',
    'touch down',
    'trackpad start',
    'selection round trip',
    'controller replacement',
    'dispose',
  ]) {
    testWidgets('source-absent jump revoked by $cancellation', (t) async {
      final c = await variedChat();
      final source = c.connections.single;
      await c.deleteConnection('a');
      final original = c.current!;
      expect(c.readOnly, isTrue);
      await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
      await t.pumpAndSettle();
      final list = find.descendant(
          of: find.byType(TranscriptLatest), matching: find.byType(ListView));
      final scroll = t.widget<ListView>(list).controller!;
      await t.tap(find.byTooltip('Jump to latest'));
      final jumped = scroll.offset;
      TestGesture? gesture;
      ChatController? replacement;
      // Revoke before the next layout discovers the taller trailing rows.
      switch (cancellation) {
        case 'source restored':
          await c.addConnection(source, '');
          expect(c.readOnly, isFalse);
        case 'source round trip':
          await c.addConnection(source, '');
          await c.deleteConnection('a');
          expect(c.connections, isEmpty);
          expect(c.current, same(original));
          expect(c.readOnly, isTrue);
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
          final other = ChatSession(
              id: 'other', connectionId: original.connectionId, model: 'small');
          c.sessions.add(other);
          c.select(other);
          c.select(original);
          await t.pump();
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
            reason:
                'Revoked source-absent corrections must not move the reader');
        expect(scroll.position.extentAfter, greaterThan(1));
      }
      if (cancellation == 'trackpad start') {
        await gesture!.panZoomEnd();
      } else {
        await gesture?.up();
      }
      // A new activation can converge after the source settles, including
      // after a missing -> present -> missing round trip.
      if (cancellation.startsWith('source')) {
        await t.tap(find.byTooltip('Jump to latest'));
        await t.pumpAndSettle();
        expect(scroll.position.extentAfter, lessThanOrEqualTo(1));
      }
      await t.pumpWidget(const SizedBox());
      await t.pump();
      expect(t.takeException(), isNull);
      c.dispose();
      replacement?.dispose();
    });
  }
}
