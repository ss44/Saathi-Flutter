import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'controller_http_test.dart' show makeStore;

void main() {
  for (final width in [360.0, 390.0]) {
    for (final keyboard in [0.0, 300.0]) {
      for (final count in [0, 2, 60]) {
        testWidgets('pinned composer $width keyboard=$keyboard history=$count',
            (t) async {
          t.view.physicalSize = Size(width, 844);
          t.view.devicePixelRatio = 1;
          t.view.viewPadding = const FakeViewPadding(bottom: 24);
          t.view.padding = FakeViewPadding(bottom: keyboard == 0 ? 24 : 0);
          t.view.viewInsets = FakeViewPadding(bottom: keyboard);
          addTearDown(t.view.reset);
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
              count,
              (i) => ChatMessage(
                  role: i.isEven ? 'user' : 'assistant',
                  content: 'Message $i')));
          await t.pumpWidget(MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!),
              home: ChatHome(controller: c)));
          final input = find.byKey(const Key('composer'));
          await t.enterText(
              input, List.filled(12, 'Multiline draft').join('\n'));
          await t.pumpAndSettle();
          final safe =
              find.ancestor(of: input, matching: find.byType(SafeArea)).first;
          final usableBottom = 844 - keyboard;
          expect(t.getBottomLeft(safe).dy, closeTo(usableBottom, .01));
          final before = t.getRect(input);
          expect(before.bottom,
              lessThanOrEqualTo(usableBottom - (keyboard == 0 ? 24 : 0)));
          expect(find.byTooltip('Send').hitTestable(), findsOneWidget);
          if (count == 0) {
            final empty = find
                .ancestor(
                    of: find.text('A little space to think.'),
                    matching: find.byType(Center))
                .first;
            expect(
                t.getBottomLeft(empty).dy, closeTo(t.getTopLeft(safe).dy, .01));
            expect(t.getTopLeft(empty).dy,
                closeTo(t.getBottomLeft(find.byType(AppBar)).dy, .01));
          }
          if (count > 0) {
            final list = find.ancestor(
                of: find.byType(MessageView).first,
                matching: find.byType(ListView));
            expect(
                t.getBottomLeft(list).dy, closeTo(t.getTopLeft(safe).dy, .01));
            if (count == 60) {
              await t.drag(list, const Offset(0, -400));
              await t.pumpAndSettle();
              expect(
                  t
                      .state<ScrollableState>(find
                          .descendant(
                              of: list, matching: find.byType(Scrollable))
                          .first)
                      .position
                      .pixels,
                  greaterThan(0));
              expect(t.getRect(input), before);
              final last = find.byKey(ValueKey('${c.current!.id}-59'));
              await t.scrollUntilVisible(last, 200,
                  maxScrolls: 200,
                  scrollable: find
                      .descendant(of: list, matching: find.byType(Scrollable))
                      .first);
              await Scrollable.ensureVisible(t.element(last), alignment: 1);
              await t.pumpAndSettle();
              expect(last.hitTestable(), findsOneWidget);
              expect(t.getBottomLeft(last).dy,
                  lessThanOrEqualTo(t.getTopLeft(safe).dy));
              expect(t.getRect(input), before);
            }
          }
          // A short feedback pane must consume only its actual height, not
          // leave a flex allocation's unused space below the input.
          c.error = 'Connection needs attention';
          c.pauseQueue('Paused');
          await t.pumpAndSettle();
          expect(find.byKey(const Key('chat-feedback')), findsOneWidget);
          expect(t.getBottomLeft(safe).dy, closeTo(usableBottom, .01),
              reason: 'feedback must not lift the composer off the bottom');
          expect(t.takeException(), isNull);
          c.error = List.filled(100, 'Recovery information').join(' ');
          c.pauseQueue('Paused');
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          expect(t.getBottomLeft(safe).dy, closeTo(usableBottom, .01));
          expect(find.byTooltip('Send').hitTestable(), findsOneWidget);
          await t.pumpWidget(const SizedBox());
          c.dispose();
        });
      }
    }
  }
}
