import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/canonical_connection.dart';
import 'canonical_combined_controller_test.dart' as fixture;

class RealHttp extends HttpOverrides {}

Future<void> settleGateway(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'reconnect retains named connection identity when addresses match',
      (tester) => HttpOverrides.runWithHttpOverrides(() async {
            late ChatController c;
            late fixture.NativeHost host;
            late ChatSession original;
            await tester.runAsync(() async {
              final result = await fixture.setup();
              c = result.$1;
              host = result.$2;
              await c.addConnection({
                'id': 'second',
                'name': 'Second named host',
                'type': 'hermesGateway',
                'url': host.url
              }, '');
              original = ChatSession(
                  id: 'second-chat',
                  connectionId: 'second',
                  model: 'Hermes',
                  canonicalProfileId: 'profile',
                  remoteSessionId: 'chat');
              c.sessions.add(original);
              c.select(original);
            });
            await tester.pumpWidget(MaterialApp(
                home: CanonicalConnectionPage(
                    controller: c,
                    connection: c.connections.last,
                    session: original)));
            await tester.enterText(
                find.widgetWithText(TextField, 'Host-issued invite JSON'),
                host.invite);
            await tester
                .ensureVisible(find.text('Trust this host and connect'));
            await tester.runAsync(() async {
              await tester.tap(find.text('Trust this host and connect'));
            });
            await settleGateway(tester);
            expect(c.current, same(original));
            expect(c.current!.connectionId, 'second');
            expect(c.canonical, isNotNull,
                reason: 'Reconnect must finish on the original owner; '
                    'requests=${host.requests.map((r) => r['method']).join(', ')}; '
                    'error=${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).where((s) => s?.startsWith('Could not') ?? false).join(', ')}');
            expect(c.canonical!.connected, isTrue);
            expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                isEmpty);
            await tester.runAsync(() async {
              await c.canonical?.close();
            });
            await tester.pumpWidget(const SizedBox());
          }, RealHttp()));
  testWidgets(
      'failed profile reconnect keeps original retry and fresh invite reachable',
      (tester) => HttpOverrides.runWithHttpOverrides(() async {
            late ChatController c;
            late fixture.NativeHost host;
            await tester.runAsync(() async {
              final result = await fixture.setup();
              c = result.$1;
              host = result.$2;
              host.profileId = 'different-profile';
              await c.connectCanonical(c.connections.single, host.invite);
            });
            final original = c.current!;
            await tester.pumpWidget(MaterialApp(
                home: CanonicalConnectionPage(
                    controller: c,
                    connection: c.connections.single,
                    session: original)));
            await settleGateway(tester);
            final requests = host.requests.length;
            await tester.tap(find.text('Open original conversation'));
            await tester.pumpAndSettle();
            expect(c.current, same(original));
            expect(host.requests.length, requests,
                reason: 'Wrong profile must not resume original ID');
            await tester.tap(find.text('Use a fresh invite'));
            await tester.pumpAndSettle();
            expect(find.text('Host-issued invite JSON'), findsOneWidget);
            await tester.runAsync(() async {
              await c.canonicalFor(c.connections.single)?.close();
            });
            await tester.pumpWidget(const SizedBox());
          }, RealHttp()));
  testWidgets(
      'old profile rows disappear when a replacement gateway listing fails',
      (tester) => HttpOverrides.runWithHttpOverrides(() async {
            late ChatController c;
            late fixture.NativeHost host;
            await tester.runAsync(() async {
              final result = await fixture.setup();
              c = result.$1;
              host = result.$2;
            });
            await tester.pumpWidget(MaterialApp(
                home: CanonicalConnectionPage(
                    controller: c, connection: c.connections.single)));
            await settleGateway(tester);
            expect(find.text('Native A'), findsOneWidget);
            host.profileId = 'different-profile';
            host.listFails = true;
            await tester.runAsync(() => expectLater(
                c.connectCanonical(c.connections.single, host.invite),
                throwsA(isA<Exception>())));
            await tester.pumpAndSettle();
            expect(find.text('Native A'), findsNothing);
            await tester.runAsync(() async {
              await c.canonicalFor(c.connections.single)?.close();
            });
            await tester.pumpWidget(const SizedBox());
          }, RealHttp()));
  for (final width in [360.0, 390.0]) {
    testWidgets(
        'gateway-first new conversation at $width with large text and keyboard',
        (tester) => HttpOverrides.runWithHttpOverrides(() async {
              tester.view.physicalSize = Size(width, 800);
              tester.view.devicePixelRatio = 1;
              tester.view.viewInsets = const FakeViewPadding(bottom: 260);
              tester.platformDispatcher.textScaleFactorTestValue = 2;
              addTearDown(() {
                tester.view.resetPhysicalSize();
                tester.view.resetDevicePixelRatio();
                tester.view.resetViewInsets();
                tester.platformDispatcher.clearTextScaleFactorTestValue();
              });
              late ChatController c;
              late fixture.NativeHost host;
              await tester.runAsync(() async {
                final result = await fixture.setup();
                c = result.$1;
                host = result.$2;
                host.creationEnabled = true;
                await c.connectCanonical(c.connections.single, host.invite);
              });
              tester.binding
                  .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
              await tester
                  .pumpWidget(MaterialApp(home: ChatHome(controller: c)));
              Future<void> settle() async {
                for (var i = 0; i < 10; i++) {
                  await tester.pump(const Duration(milliseconds: 20));
                  await tester.runAsync(() =>
                      Future<void>.delayed(const Duration(milliseconds: 20)));
                }
                await tester.pumpAndSettle();
              }

              await tester.tap(find.byTooltip('New conversation'));
              await settle();
              await tester.scrollUntilVisible(
                  find.text('Open Hermes gateway'), 160,
                  scrollable: find
                      .descendant(
                          of: find.byType(ListView).last,
                          matching: find.byType(Scrollable))
                      .first);
              await tester.pumpAndSettle();
              await tester.tap(find.text('Open Hermes gateway'));
              await settle();
              await tester.scrollUntilVisible(
                  find.text('New Hermes conversation'), 160,
                  scrollable: find
                      .descendant(
                          of: find.byType(ListView).last,
                          matching: find.byType(Scrollable))
                      .first);
              await tester.pumpAndSettle();
              await tester.tap(find.text('New Hermes conversation'));
              await settle();
              expect(tester.takeException(), isNull);
              expect(c.current!.remoteSessionId, 'new-native');
              expect(c.canonical!.connected, isTrue);
              expect(find.byKey(const Key('composer')), findsOneWidget);
              expect(
                  host.requests.where((r) => r['method'] == 'session.create'),
                  hasLength(1));
              expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                  isEmpty);
              await tester.pumpWidget(const SizedBox());
              await settle();
            }, RealHttp()));
    testWidgets(
        'combined canonical ChatHome $width 2x keyboard approval controls long draft wheel/live edge',
        (tester) => HttpOverrides.runWithHttpOverrides(() async {
              tester.view.physicalSize = Size(width, 800);
              tester.view.devicePixelRatio = 1;
              tester.view.viewInsets = const FakeViewPadding(bottom: 260);
              tester.platformDispatcher.textScaleFactorTestValue = 2;
              addTearDown(() {
                tester.view.resetPhysicalSize();
                tester.view.resetDevicePixelRatio();
                tester.view.resetViewInsets();
                tester.platformDispatcher.clearTextScaleFactorTestValue();
              });
              late ChatController c;
              late fixture.NativeHost host;
              await tester.runAsync(() async {
                final result = await fixture.setup();
                c = result.$1;
                host = result.$2;
                host.history = [
                  for (var i = 0; i < 50; i++)
                    {
                      'row_id': i + 1,
                      'role': i.isEven ? 'user' : 'assistant',
                      'content':
                          'Canonical history row $i with enough readable text to wrap on a narrow phone.',
                    }
                ];
                await c.refreshCanonical();
              });
              tester.binding
                  .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
              await tester
                  .pumpWidget(MaterialApp(home: ChatHome(controller: c)));
              Future<void> settle() async {
                for (var i = 0; i < 10; i++) {
                  await tester.pump(const Duration(milliseconds: 20));
                  await tester.runAsync(() =>
                      Future<void>.delayed(const Duration(milliseconds: 20)));
                }
              }

              final composer = find.byKey(const Key('composer'));
              await tester.runAsync(() => c.send('first'));
              await settle();
              await tester.enterText(composer, 'A long retained draft. ' * 30);
              await tester.pump();
              host.prompts = [
                {
                  'kind': 'approval',
                  'prompt_id': 'approve',
                  'command': 'echo reviewable fixture',
                  'execution_generation': 4,
                  'question':
                      'Review this explicitly requested action before allowing it. ' *
                          8,
                  'choices': ['once', 'deny']
                }
              ];
              await tester.runAsync(c.refreshCanonical);
              await settle();
              expect(tester.takeException(), isNull);
              expect(find.text('Review action'), findsOneWidget);
              final before = host.requests
                  .where((r) => r['method'] == 'prompt.submit')
                  .length;
              await tester.tap(find.text('Review action'));
              await settle();
              await tester.ensureVisible(find.text('once'));
              await tester.tap(find.text('once'));
              await settle();
              expect(
                  host.requests.where((r) => r['method'] == 'approval.respond'),
                  hasLength(1));
              expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                  hasLength(before));
              host.prompts = [
                {
                  'kind': 'clarify',
                  'prompt_id': 'clarify',
                  'execution_generation': 4,
                  'question': 'Which destination should this work use?',
                  'choices': ['Original source']
                }
              ];
              await tester.runAsync(c.refreshCanonical);
              await settle();
              await tester.tap(find.text('Answer needed'));
              await settle();
              await tester.enterText(
                  find.widgetWithText(TextField, 'Your answer'),
                  'Keep the original destination');
              await tester.tap(find.text('Answer'));
              await settle();
              expect(
                  host.requests.where((r) => r['method'] == 'clarify.respond'),
                  hasLength(1));
              expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                  hasLength(before));
              for (final label in [
                'Guide current work',
                'Correct current work'
              ]) {
                await tester
                    .tap(find.byTooltip('Use draft while Hermes works'));
                await settle();
                await tester.tap(find.text(label));
                await settle();
                expect(tester.widget<TextField>(composer).controller!.text,
                    isEmpty);
                await tester.enterText(
                    composer, 'A long retained draft. ' * 30);
                await tester.pump();
              }
              final transcript = find
                  .descendant(
                      of: find.byType(ListView),
                      matching: find.byType(Scrollable))
                  .first;
              final scroll = tester.state<ScrollableState>(transcript).position;
              scroll.jumpTo(scroll.maxScrollExtent);
              await tester.pump();
              final position = tester.getCenter(transcript);
              await tester.sendEventToBinding(PointerScrollEvent(
                  position: position, scrollDelta: const Offset(0, -700)));
              await tester.pump();
              final away = scroll.extentAfter;
              expect(away, greaterThan(120));
              host.delta('Native live output');
              await settle();
              expect(scroll.extentAfter, greaterThan(120));
              final viewport = tester.getRect(transcript);
              final anchor = tester
                  .widgetList<MessageView>(find.byType(MessageView))
                  .firstWhere((m) {
                if (!m.text.startsWith('Canonical history row')) return false;
                final rect = tester.getRect(find.byWidget(m));
                return rect.bottom > viewport.top && rect.top < viewport.bottom;
              });
              final anchorText = anchor.text;
              final anchorY = tester.getTopLeft(find.byWidget(anchor)).dy;
              host.history = host.history!.skip(10).toList();
              await tester.runAsync(c.refreshCanonical);
              await settle();
              final anchored = find.byWidgetPredicate(
                  (w) => w is MessageView && w.text == anchorText);
              expect(anchored, findsOneWidget,
                  reason:
                      'A surviving reader row stays mounted after compression reset');
              expect(tester.getTopLeft(anchored).dy, closeTo(anchorY, 2),
                  reason:
                      'Compression must preserve the surviving reader anchor');
              // A trackpad pan is distinct from a pointer wheel.
              final trackpad =
                  await tester.createGesture(kind: PointerDeviceKind.trackpad);
              await trackpad.panZoomStart(position);
              await trackpad.panZoomUpdate(position, pan: const Offset(0, 100));
              await trackpad.panZoomEnd();
              await tester.pumpAndSettle();
              host.delta(' More output for an older-history reader.');
              await settle();
              expect(scroll.extentAfter, greaterThan(120));
              for (var i = 0; i < 8; i++) {
                scroll.jumpTo(scroll.maxScrollExtent);
                await tester.pump();
                if (scroll.extentAfter < 2) break;
              }
              expect(scroll.extentAfter, lessThan(2),
                  reason:
                      'Reader must actually reach live edge before the next delta');
              host.delta(' Live edge grows with this new output. ' * 15);
              await settle();
              expect(scroll.extentAfter, lessThan(2),
                  reason:
                      'stream=${c.streamingText?.length} pixels=${scroll.pixels} max=${scroll.maxScrollExtent}');
              await tester.tap(find.byTooltip('Use draft while Hermes works'));
              await settle();
              await tester.tap(find.text('Interrupt, then queue draft'));
              await settle();
              expect(c.outbox, hasLength(1));
              expect(c.runPending, isTrue,
                  reason: 'Stop ACK is not terminal proof');
              expect(host.requests.where((r) => r['method'] == 'prompt.submit'),
                  hasLength(1));
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
              await settle();
            }, RealHttp()));
  }
}
