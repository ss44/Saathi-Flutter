import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'controller_http_test.dart' show makeStore;

void main() {
  for (final reduced in [false, true]) {
    testWidgets('pending bubble glow respects reduced motion=$reduced',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: const Scaffold(
                body: MessageView(text: 'Pending', user: true, pending: true),
              ))));
      final bubble = find.descendant(
          of: find.byType(MessageView), matching: find.byType(DecoratedBox));
      BoxShadow shadow() =>
          (tester.widget<DecoratedBox>(bubble).decoration as BoxDecoration)
              .boxShadow!
              .single;
      final initial = shadow();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 700));
      expect(shadow(), reduced ? initial : isNot(initial));
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('unknown outcome requires explicit abandon confirmation',
      (t) async {
    final c = ChatController(await makeStore(),
        coreFactory: () => SaathiCore(
            client: MockClient((_) async => http.Response('{}', 500))));
    await c.load();
    final connection = {
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'https://example.com'
    };
    await c.addConnection(connection, '');
    await c.newSession(connection, 'small', '');
    c.submit('Unknown');
    c.submit('Held');
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pump();
    expect(find.text('Abandon held outbox'), findsOneWidget);
    await t.ensureVisible(find.text('Abandon held outbox'));
    await t.tap(find.text('Abandon held outbox'));
    await t.pumpAndSettle();
    expect(find.textContaining('does not stop the server'), findsOneWidget);
    await t.tap(find.text('Keep blocked'));
    await t.pumpAndSettle();
    expect(c.uncertainInput, isNotNull);
    expect(c.outbox.single.text, 'Held');
    await t.tap(find.text('Abandon held outbox'));
    await t.pumpAndSettle();
    await t.tap(find.text('Abandon all'));
    await t.pumpAndSettle();
    expect(c.uncertainInput, isNull);
    expect(c.outbox, isEmpty);
    expect(c.queueStatus, isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  for (final width in [390.0, 360.0]) {
    testWidgets('editable pending composer retains newer draft at $width',
        (t) async {
      t.view.physicalSize = Size(width, 1000);
      t.view.devicePixelRatio = 1;
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(t.view.resetViewInsets);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final response = Completer<http.Response>();
      final c = ChatController(await makeStore(),
          coreFactory: () =>
              SaathiCore(client: MockClient((_) => response.future)));
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
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(width == 360 ? 2 : 1)),
              child: child!),
          home: ChatHome(controller: c)));
      final input = find.byKey(const Key('composer'));
      await t.enterText(input, 'First');
      await t.pump();
      await t.tap(find.byTooltip('Send'));
      await t.pump();
      expect(t.widget<TextField>(input).enabled, isTrue);
      expect(t.widget<TextField>(input).controller!.text, isEmpty);
      await t.enterText(input, 'Long followup ' * 80);
      await t.pump();
      await t.tap(find.byTooltip('Send'));
      await t.pump();
      expect(find.text('Queued'), findsNothing);
      final pending = find.text(('Long followup ' * 80).trim());
      final transcript = find
          .descendant(
              of: find.byType(ListView), matching: find.byType(Scrollable))
          .first;
      await t.scrollUntilVisible(pending, 180, scrollable: transcript);
      expect(t.widget<Text>(pending).style?.fontStyle, FontStyle.italic);
      final cancel = find.byTooltip('Cancel pending message');
      await t.enterText(input, 'Newer draft');
      await t.ensureVisible(cancel);
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(cancel);
      await t.pump();
      expect(c.outbox, isEmpty);
      response.complete(
          http.Response('{"choices":[{"message":{"content":"Done"}}]}', 200));
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await t.pump();
      expect(t.widget<TextField>(input).controller!.text, 'Newer draft');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
