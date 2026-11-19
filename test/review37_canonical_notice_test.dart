import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'gateway/canonical_combined_controller_test.dart' as fixture;

class RealHttp extends HttpOverrides {}

void main() {
  for (final scenario in ['guide', 'preview limit']) {
    for (final width in [360.0, 390.0]) {
      testWidgets(
          'independent: $scenario retains ongoing canonical thinking $width',
          (t) => HttpOverrides.runWithHttpOverrides(() async {
                t.view.physicalSize = Size(width, 900);
                t.view.devicePixelRatio = 1;
                t.view.viewInsets = const FakeViewPadding(bottom: 220);
                t.platformDispatcher.textScaleFactorTestValue = 2;
                addTearDown(() {
                  t.view.resetPhysicalSize();
                  t.view.resetDevicePixelRatio();
                  t.view.resetViewInsets();
                  t.platformDispatcher.clearTextScaleFactorTestValue();
                });
                late ChatController c;
                late fixture.NativeHost host;
                await t.runAsync(() async {
                  final result = await fixture.setup();
                  c = result.$1;
                  host = result.$2;
                });
                t.binding
                    .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
                await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
                Future<void> flush() async {
                  for (var i = 0; i < 10; i++) {
                    await t.pump(const Duration(milliseconds: 20));
                    await t.runAsync(() =>
                        Future<void>.delayed(const Duration(milliseconds: 20)));
                  }
                }

                await t.runAsync(() => c.send('first'));
                await flush();
                await t.drag(
                    find.byType(ListView).first, const Offset(0, -1600));
                await flush();
                expect(find.byType(BusyThinking), findsOneWidget,
                    reason:
                        'initial pending=${c.runPending} problem=${c.canonical!.problem} connected=${c.canonical!.observable}');
                if (scenario == 'guide') {
                  await t.enterText(find.byKey(const Key('composer')),
                      'Continue with the original task');
                  await t.pump();
                  await t.tap(find.byTooltip('Use draft while Hermes works'));
                  await flush();
                  await t.tap(find.text('Guide current work'));
                  await flush();
                  expect(
                      host.requests
                          .where((r) => r['method'] == 'session.steer'),
                      hasLength(1));
                  expect(c.canonical!.problem, contains('Guidance accepted'));
                } else {
                  await t.runAsync(() async {
                    host.delta('x' * (256 * 1024 + 1));
                  });
                  await flush();
                  expect(c.canonical!.problem, contains('preview limit'));
                }
                expect(c.canonical!.observable, isTrue);
                expect(c.canonical!.client.run!.state, GatewayRunState.running);
                expect(c.runPending, isTrue);
                expect(
                    host.requests.where((r) => r['method'] == 'prompt.submit'),
                    hasLength(1));
                await t.drag(
                    find.byType(ListView).first, const Offset(0, -1600));
                await flush();
                final thinking = find.byType(BusyThinking).evaluate().length;
                await t.pumpWidget(const SizedBox());
                await flush();
                expect(thinking, 1,
                    reason:
                        'Informational guidance/preview feedback is neither completion nor exhausted observation');
              }, RealHttp()));
    }
  }
}
