import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_activity/activity_model.dart';
import 'package:saathi/agent_activity/activity_strip.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';

import '../gateway/canonical_combined_controller_test.dart' as fixture;

class _RealHttp extends HttpOverrides {}

void main() {
  for (final width in [360.0, 390.0]) {
    testWidgets(
        'growing draft retains reader and editing state during native '
        'stream/activity $width 2x keyboard', (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() {
          tester.view.reset();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        late ChatController controller;
        late fixture.NativeHost host;
        await tester.runAsync(() async {
          final result = await fixture.setup();
          controller = result.$1;
          host = result.$2;
          host.history = [
            for (var i = 0; i < 60; i++)
              {
                'row_id': i + 1,
                'role': i.isEven ? 'user' : 'assistant',
                'content': 'History row $i with enough text to wrap.',
              }
          ];
          await controller.refreshCanonical();
        });
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(MaterialApp(
          home: ChatHome(controller: controller),
        ));
        Future<void> settle() async {
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)));
          }
        }

        await tester.runAsync(() => controller.send('first'));
        await settle();
        final transcript = find
            .descendant(
                of: find.byType(ListView), matching: find.byType(Scrollable))
            .first;
        final reader = tester.state<ScrollableState>(transcript).position;
        reader.jumpTo(reader.maxScrollExtent / 2);
        await tester.pumpAndSettle();
        final pixels = reader.pixels;
        final viewport = tester.getRect(transcript);
        final anchor = tester
            .widgetList<MessageView>(find.byType(MessageView))
            .firstWhere((message) {
          final rect = tester.getRect(find.byWidget(message));
          return rect.bottom > viewport.top && rect.top < viewport.bottom;
        });
        final anchorY = tester.getTopLeft(find.byWidget(anchor)).dy;
        final input = find.byKey(const Key('composer'));
        await tester.enterText(input, 'Short');
        await tester.pumpAndSettle();
        final shortHeight = tester.getSize(input).height;
        await tester.enterText(input, 'A retained wrapped draft. ' * 100);
        await tester.pumpAndSettle();
        expect(tester.getSize(input).height, closeTo(shortHeight * 2, 1));
        expect(reader.pixels, closeTo(pixels, .01));
        final editing = tester.widget<TextField>(input).controller!;
        editing.selection = TextSelection(
            baseOffset: editing.text.length - 5,
            extentOffset: editing.text.length - 1);
        await tester.pumpAndSettle();
        final value = editing.value;
        final editable = tester.state<EditableTextState>(
            find.descendant(of: input, matching: find.byType(EditableText)));
        final draftScroll = tester.state<ScrollableState>(
            find.descendant(of: input, matching: find.byType(Scrollable)));
        await tester.drag(input, const Offset(0, 70));
        await tester.pumpAndSettle();
        final draftOffset = draftScroll.position.pixels;
        final inputBottom = tester.getBottomLeft(input).dy;
        // Controlled telemetry through the actual ChatHome-owned activity model;
        // this checks layout/edit ownership, not native telemetry transport.
        final model = tester
            .widget<AgentActivityStrip>(find.byType(AgentActivityStrip))
            .model;
        final binding = model.bind(
          connectionId: 'native',
          revision: 'fixture',
          connectionName: 'Native',
          localChatId: controller.current!.id,
          runId: 'run',
          title: 'Fixture work',
        );
        model.updateStatus(binding, ActivityStatus.running);
        model.event(binding, {
          'event': 'subagent.start',
          'run_id': 'run',
          'seq': 1,
          'subagent_id': 'child',
          'goal': 'Fixture child activity',
        });
        await settle();
        host.delta('A visible streamed reply ' * 10);
        await settle();
        expect(controller.streamingText, contains('visible streamed reply'));
        model.event(binding, {
          'event': 'subagent.complete',
          'run_id': 'run',
          'seq': 2,
          'subagent_id': 'child',
          'status': 'completed',
        });
        await settle();
        expect(editing.value, value);
        expect(editable.widget.focusNode.hasFocus, isTrue);
        expect(draftScroll.position.pixels, closeTo(draftOffset, .01));
        expect(reader.pixels, closeTo(pixels, .01));
        final surviving = find.byWidgetPredicate(
            (widget) => widget is MessageView && widget.text == anchor.text);
        expect(tester.getTopLeft(surviving).dy, closeTo(anchorY, .01));
        expect(tester.getBottomLeft(input).dy, closeTo(inputBottom, .01));
        expect(find.byTooltip('Send').hitTestable(), findsOneWidget);
        await tester.enterText(input, 'Short');
        await tester.pumpAndSettle();
        expect(tester.getSize(input).height, shortHeight);
        expect(reader.pixels, closeTo(pixels, .01));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await settle();
      }, _RealHttp());
    });
  }
}
