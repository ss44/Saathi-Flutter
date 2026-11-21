import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'runtime_flow_test.dart' show RuntimeFixture, RealHttp;
import 'runtime_recovery_test.dart' show connect;

// The independent review's actual ChatHome + localhost native SSE wheel repro,
// with the same ownership boundary exercised by the other reader inputs.
void main() {
  for (final input in [
    'wheel',
    'trackpad',
    'drag',
    'ballistic',
    'wheel before scheduled frame',
    'source switch before scheduled frame',
    'already at bottom',
    'stream crosses threshold',
  ]) {
    testWidgets('$input preserves native stream scroll ownership', (t) async {
      HttpOverrides.global = null;
      late RuntimeFixture f;
      late ChatController c;
      await t.runAsync(() async {
        f = RuntimeFixture();
        await f.start();
        c = await connect(f);
        c.current!.messages.addAll(List.generate(
            60,
            (i) => ChatMessage(
                role: 'model',
                content:
                    'History row $i with enough text to make the conversation scroll.')));
      });
      Future<void> network() async {
        for (var i = 0; i < 12; i++) {
          await t.pump(const Duration(milliseconds: 30));
          await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
      }

      Future<void> emit(String text) async {
        await t.runAsync(() async {
          f.emit('message.delta', {'delta': text});
        });
        // Deliver fake-scheduler stream continuations without running the
        // post-frame callback whose ownership this test is about to revoke.
        for (var i = 0;
            i < 30 && !(c.streamingText?.contains(text) ?? false);
            i++) {
          await t.idle();
          await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
        }
        expect(c.streamingText, contains(text));
      }

      try {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await http.runWithClient(
            () => t.pumpWidget(MaterialApp(home: ChatHome(controller: c))),
            () => IOClient(RealHttp().createHttpClient(null)));
        await t.enterText(find.byKey(const Key('composer')), 'Start');
        await t.pump();
        await t.tap(find.byTooltip('Send'));
        await network();
        final list = find.byType(ListView).first;
        final scroller = t.widget<ListView>(list).controller!;
        expect(c.streamingText, isNotNull);
        expect(scroller.position.extentAfter, lessThan(120));
        final p = t.getCenter(list);
        final oldMax = scroller.position.maxScrollExtent;
        if (input == 'stream crosses threshold') {
          await t.sendEventToBinding(PointerScrollEvent(
            position: p,
            scrollDelta: Offset(0, -scroller.position.viewportDimension + 1),
            kind: PointerDeviceKind.mouse,
          ));
          await t.pumpAndSettle();
          expect(find.byTooltip('Jump to latest'), findsNothing);
          final before = scroller.offset;
          await emit(
              List.filled(30, '\n\nStreaming grows below the reader.').join());
          await network();
          expect(scroller.offset, before);
          expect(find.byTooltip('Jump to latest'), findsOneWidget);
          await t.tap(find.byTooltip('Jump to latest'));
          await t.pump();
          await emit(List.filled(20, '\n\nFollowing again.').join());
          await network();
          expect(scroller.position.extentAfter, lessThan(2));
          expect(find.byTooltip('Jump to latest'), findsNothing);
          return;
        }
        if (input == 'already at bottom') {
          await emit(
              List.filled(30, '\n\nMore visible output at the live edge.')
                  .join());
          await network();
          expect(scroller.position.maxScrollExtent, greaterThan(oldMax + 500));
          expect(scroller.position.extentAfter, lessThan(120));
          return;
        }
        if (input.contains('before scheduled frame')) {
          await emit(' More visible text');
        }
        if (input == 'source switch before scheduled frame') {
          final other = ChatSession(
              id: 'other-reader',
              connectionId: c.current!.connectionId,
              model: 'other',
              messages: List.generate(
                  90,
                  (i) => ChatMessage(
                      role: 'model', content: 'Other conversation row $i')));
          c.sessions.add(other);
          c.select(other);
          await t.pump();
          expect(scroller.position.extentAfter, greaterThan(500));
          return;
        }
        if (input == 'trackpad') {
          final gesture =
              await t.createGesture(kind: PointerDeviceKind.trackpad);
          await gesture.panZoomStart(p);
          await gesture.panZoomUpdate(p, pan: const Offset(0, 20));
          await gesture.panZoomUpdate(p, pan: const Offset(0, 920));
          await gesture.panZoomEnd();
        } else if (input == 'drag') {
          await t.drag(list, const Offset(0, 900));
        } else if (input == 'ballistic') {
          await t.fling(list, const Offset(0, 900), 1400);
          await t.pump(const Duration(milliseconds: 80));
          expect(scroller.position.isScrollingNotifier.value, isTrue);
        } else {
          await t.sendEventToBinding(PointerScrollEvent(
              position: p,
              scrollDelta: const Offset(0, -900),
              kind: PointerDeviceKind.mouse));
        }
        await t.pump();
        final before = scroller.position.extentAfter;
        expect(before, greaterThan(500));
        if (!input.contains('before scheduled frame')) {
          await emit(' More visible text');
        }
        await network();
        final after = scroller.position.extentAfter;
        expect(after, greaterThan(500),
            reason:
                'New output must not pull an older-history reader to bottom');
        // Returning to the live edge must restore following, not leave it off.
        expect(find.byTooltip('Jump to latest'), findsOneWidget);
        await t.tap(find.byTooltip('Jump to latest'));
        await t.pump();
        await emit(List.filled(20, '\n\nFollow again.').join());
        await network();
        expect(scroller.position.extentAfter, lessThan(120));
      } finally {
        await t.pumpWidget(const SizedBox());
        c.dispose();
        await t.runAsync(f.close);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }
}
