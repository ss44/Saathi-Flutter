import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/thinking_phrases.dart';

class _FirstPhraseRandom extends Fake implements Random {
  @override
  int nextInt(int max) => max == visibleThinkingPhrases.length
      ? visibleThinkingPhrases.indexOf('Reconnecting the tin-can hotline')
      : 0;
}

void main() {
  testWidgets('Android elapsed wait pauses display updates while backgrounded',
      (tester) async {
    var now = DateTime.utc(2026, 11, 21);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BusyThinking(busy: true, clock: () => now))));
    expect(find.text('0.0s'), findsOneWidget);
    now = now.add(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('0.1s'), findsOneWidget);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    now = now.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('0.1s'), findsOneWidget);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('5.1s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'Android thinking text matches plugin copy and ten-second cadence',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BusyThinking(busy: true, random: Random(7)))));
    final finder = find.byKey(const Key('thinking-quip'));
    final initial = tester.widget<Text>(finder);
    expect(initial.style?.fontStyle, FontStyle.italic);
    expect(initial.data, endsWith('...'));
    expect(initial.data, isNot(contains('A little whimsy')));
    expect(find.text('Waiting for reply'), findsNothing);
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.text('0.0s'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 9999));
    expect(tester.widget<Text>(finder).data, initial.data);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.widget<Text>(finder).data, isNot(initial.data));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android displays satirical copy without a label',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BusyThinking(busy: true, random: _FirstPhraseRandom()))));
    expect(find.text('Reconnecting the tin-can hotline...'), findsOneWidget);
    expect(find.bySemanticsLabel('Waiting for reply'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'Android thinking text remains readable at narrow width and large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child:
                Scaffold(body: BusyThinking(busy: true, random: Random(7))))));
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
