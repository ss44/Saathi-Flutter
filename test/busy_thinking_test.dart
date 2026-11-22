import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/thinking_phrases.dart';

Widget host(
        {bool busy = true,
        bool reduced = false,
        double width = 390,
        double scale = 1}) =>
    MaterialApp(
        home: MediaQuery(
            data: MediaQueryData(
                size: Size(width, 800),
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduced),
            child: Scaffold(
                body: SizedBox(
                    width: width,
                    child: BusyThinking(busy: busy, random: Random(7))))));

void main() {
  test('rotation keeps the jokes and drops phrases that look like status', () {
    expect(importedThinkingPhrases, hasLength(225));
    expect(newThinkingPhrases, hasLength(200));
    expect(visibleThinkingPhrases.toSet(),
        hasLength(visibleThinkingPhrases.length));
    for (final phrase in [
      'Reconnecting',
      'Disconnecting',
      'Corrupted data',
      'Encrypting secrets',
      'Checking for updates',
      '500 Internal Server Error',
      'Buffering video',
      'Loading ad',
      'Erasing',
    ]) {
      expect(importedThinkingPhrases, contains(phrase));
      expect(visibleThinkingPhrases, isNot(contains(phrase)));
    }
    expect(
        visibleThinkingPhrases, contains('Reconnecting the tin-can hotline'));
    expect(visibleThinkingPhrases, containsAll(newThinkingPhrases));
  });
  testWidgets(
      'loader animates, preserves phrase cadence through native polls and disposes',
      (tester) async {
    await tester.pumpWidget(host());
    final first =
        tester.widget<Text>(find.byKey(const Key('thinking-quip'))).data;
    final turns = tester
        .widget<AnimatedRotation>(find.byKey(const Key('thinking-loader')))
        .turns;
    await tester.pump(const Duration(milliseconds: 800));
    expect(
        tester
            .widget<AnimatedRotation>(find.byKey(const Key('thinking-loader')))
            .turns,
        greaterThan(turns));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.pumpWidget(host());
      await tester.pump(const Duration(seconds: 1));
    }
    expect(tester.widget<Text>(find.byKey(const Key('thinking-quip'))).data,
        isNot(first));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'rotates only after ten seconds, pauses in background, ends cleanly',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    String quip() =>
        tester.widget<Text>(find.byKey(const Key('thinking-quip'))).data!;
    final first = quip();
    await tester.pump(const Duration(seconds: 9));
    expect(quip(), first);
    await tester.pump(const Duration(seconds: 1));
    expect(quip(), isNot(first));
    expect(find.bySemanticsLabel('Waiting for reply'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final paused = quip();
    await tester.pump(const Duration(seconds: 24));
    expect(quip(), paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 10));
    expect(quip(), isNot(paused));
    await tester.pumpWidget(host(busy: false));
    expect(find.text('Waiting for reply'), findsNothing);
    await tester.pump(const Duration(seconds: 24));
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  for (final size in [(390.0, 1.0), (360.0, 2.0)]) {
    testWidgets('reduced motion is static and fits ${size.$1}/${size.$2}',
        (tester) async {
      await tester
          .pumpWidget(host(reduced: true, width: size.$1, scale: size.$2));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final first =
          tester.widget<Text>(find.byKey(const Key('thinking-quip'))).data;
      await tester.pump(const Duration(seconds: 40));
      expect(tester.widget<Text>(find.byKey(const Key('thinking-quip'))).data,
          first);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  test('shuffle bag exhausts pool and never repeats at a boundary', () {
    final bag = ThinkingShuffleBag(['a', 'b', 'c'], random: Random(4));
    String? last;
    for (var round = 0; round < 20; round++) {
      final seen = <String>{};
      for (var i = 0; i < 3; i++) {
        final next = bag.next();
        expect(next, isNot(last));
        seen.add(next);
        last = next;
      }
      expect(seen.length, 3);
    }
  });
}
