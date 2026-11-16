import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'controller_failure_test.dart' show FailingStore;

Future<void> flush(WidgetTester t) async {
  await t
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await t.pump();
}

Future<void> reachAndTap(WidgetTester t, String label) async {
  final target = find.text(label);
  final list = find
      .descendant(
          of: find.byKey(const Key('chat-feedback')),
          matching: find.byType(Scrollable))
      .first;
  await t.drag(list, const Offset(0, 3000));
  await t.pumpAndSettle();
  await t.scrollUntilVisible(target, 40, scrollable: list);
  await Scrollable.ensureVisible(t.element(target), alignment: .5);
  await t.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await t.tap(target);
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

void main() {
  for (final width in [360.0, 390.0]) {
    for (final keyboard in [280.0, 300.0]) {
      for (final storageFailure in [false, true]) {
        testWidgets(
            'recovery $width x 844 keyboard $keyboard save=$storageFailure',
            (t) async {
          t.view.physicalSize = Size(width, 844);
          t.view.devicePixelRatio = 1;
          t.view.viewInsets = FakeViewPadding(bottom: keyboard);
          addTearDown(t.view.resetViewInsets);
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final store = FailingStore(await SharedPreferences.getInstance());
          final replies = <Completer<http.Response>>[];
          final c = ChatController(store,
              coreFactory: () => SaathiCore(client: MockClient((_) {
                    final reply = Completer<http.Response>();
                    replies.add(reply);
                    return reply.future;
                  })));
          await c.load();
          final connection = {
            'id': 'a',
            'name': 'A',
            'type': 'openai',
            'url': 'https://example.com'
          };
          await c.addConnection(connection, '');
          await c.newSession(connection, 'small', '');
          await t.pumpWidget(MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!),
              home: ChatHome(controller: c)));
          final input = find.byKey(const Key('composer'));
          await t.enterText(input, 'First request');
          await t.pump();
          await t.tap(find.byTooltip('Send'));
          await flush(t);
          expect(replies, hasLength(1));
          await t.enterText(input, 'Queued followup');
          await t.pump();
          await t.tap(find.byTooltip('Send'));
          await t.pump();
          const draft =
              'Newer draft\nkeep this\nand this\nand this\nand this\nand this';
          await t.enterText(input, draft);
          await t.pump();
          store.fail = storageFailure;
          replies.single.complete(http.Response(
              storageFailure
                  ? '{"choices":[{"message":{"content":"Saved answer"}}]}'
                  : '{}',
              storageFailure ? 200 : 500));
          await flush(t);
          expect(t.takeException(), isNull);
          expect(c.outbox.single.text, 'Queued followup');
          expect(t.widget<TextField>(input).controller!.text, draft);
          if (storageFailure) {
            expect(c.unsavedChanges, isTrue);
            expect(c.current!.messages.last.content, 'Saved answer');
            store.fail = false;
            await reachAndTap(t, 'Try saving again');
            expect(c.unsavedChanges, isFalse);
            expect(replies, hasLength(1));
            await reachAndTap(t, 'Resume queue');
            await flush(t);
            expect(replies, hasLength(2));
            replies.last.complete(http.Response(
                '{"choices":[{"message":{"content":"Followup answer"}}]}',
                200));
            await flush(t);
          } else {
            expect(c.uncertainInput, isNotNull);
            await reachAndTap(t, 'Abandon held outbox');
            expect(find.textContaining('does not stop the server'),
                findsOneWidget);
            await t.ensureVisible(find.text('Keep blocked'));
            await t.tap(find.text('Keep blocked'));
            await t.pumpAndSettle();
            expect(c.uncertainInput, isNotNull);
            expect(c.outbox, hasLength(1));
            await reachAndTap(t, 'Abandon held outbox');
            await t.ensureVisible(find.text('Abandon all'));
            await t.tap(find.text('Abandon all'));
            await t.pumpAndSettle();
            expect(c.uncertainInput, isNull);
            expect(c.outbox, isEmpty);
            expect(replies, hasLength(1));
          }
          expect(t.widget<TextField>(input).controller!.text, draft);
          expect(t.widget<TextField>(input).enabled, isTrue);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
          c.dispose();
        });
      }
    }
  }
}
