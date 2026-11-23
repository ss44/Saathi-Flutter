import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/busy_thinking.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/markdown_theme.dart';
import 'package:saathi/ui/safe_markdown.dart';

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test(
      'parseSafeMarkdownLink allows http/https only and rejects unsafe schemes',
      () {
    expect(
        parseSafeMarkdownLink('https://example.com/docs')?.host, 'example.com');
    expect(parseSafeMarkdownLink('HTTPS://example.com/docs')?.scheme, 'https');
    expect(parseSafeMarkdownLink('http://127.0.0.1:8080/ok')?.scheme, 'http');
    expect(parseSafeMarkdownLink('javascript:alert(1)'), isNull);
    expect(parseSafeMarkdownLink('file:///etc/passwd'), isNull);
    expect(parseSafeMarkdownLink('data:text/html,hi'), isNull);
    expect(parseSafeMarkdownLink('mailto:test@example.com'), isNull);
    expect(parseSafeMarkdownLink('https://user:pass@example.com'), isNull);
    expect(parseSafeMarkdownLink('https://@example.com'), isNull);
    expect(parseSafeMarkdownLink('https://example.com:0/bad'), isNull);
    expect(parseSafeMarkdownLink('https://example.com:99999/bad'), isNull);
    expect(parseSafeMarkdownLink('https://example.com/has space'), isNull);
    expect(parseSafeMarkdownLink('https://example.com/a\nb'), isNull);
    expect(parseSafeMarkdownLink('/relative/path'), isNull);
    expect(parseSafeMarkdownLink(''), isNull);
    expect(parseSafeMarkdownLink(null), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'code blocks contrast with assistant bubble in ${brightness.name} theme',
        (tester) async {
      final theme = ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3E6559),
          brightness: brightness,
        ),
      );
      late Color bubbleBg;
      late Color? inlineBg;
      late Color? blockBg;
      late Color? codeFg;
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Builder(builder: (context) {
          final style = saathiMarkdownStyle(context);
          bubbleBg = Theme.of(context).colorScheme.surfaceContainerHighest;
          inlineBg = style.code?.backgroundColor;
          codeFg = style.code?.color;
          blockBg = (style.codeblockDecoration as BoxDecoration?)?.color;
          return const SizedBox.shrink();
        }),
      ));
      expect(inlineBg, isNotNull);
      expect(blockBg, isNotNull);
      expect(inlineBg, isNot(equals(bubbleBg)));
      expect(blockBg, isNot(equals(bubbleBg)));
      expect(_contrastRatio(codeFg!, blockBg!), greaterThanOrEqualTo(4.5));
    });

    testWidgets(
        'BusyThinking uses unified bubble with accessible quip contrast in ${brightness.name}',
        (tester) async {
      final theme = ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3E6559),
          brightness: brightness,
        ),
      );
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(body: BusyThinking(busy: true, random: Random(7))),
      ));
      expect(find.byKey(const Key('pending-response-bubble')), findsOneWidget);
      expect(find.byKey(const Key('thinking-elapsed')), findsOneWidget);
      final bubble = tester.widget<Container>(
        find.byKey(const Key('pending-response-bubble')),
      );
      final bg = (bubble.decoration! as BoxDecoration).color!;
      final quip = tester.widget<Text>(find.byKey(const Key('thinking-quip')));
      final fg = quip.style!.color!;
      expect(_contrastRatio(fg, bg), greaterThanOrEqualTo(4.5),
          reason: 'Waiting quip must meet WCAG AA contrast on its bubble');
      await tester.pumpWidget(const SizedBox.shrink());
    },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.linux,
        }));
  }

  testWidgets('Markdown links open safe web URLs and reject unsafe schemes',
      (tester) async {
    final opened = <Uri>[];
    var shouldSucceed = true;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageView(
          text:
              '[Docs](https://example.com/guide)\n\n[Bad](javascript:alert(1))',
          user: false,
          onOpenLink: (uri) async {
            opened.add(uri);
            return shouldSucceed;
          },
        ),
      ),
    ));
    await tester.tap(find.textContaining('Docs', findRichText: true));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://example.com/guide')]);

    await tester.tap(find.textContaining('Bad', findRichText: true));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(find.textContaining('Only web links'), findsOneWidget);

    shouldSucceed = false;
    await tester.tap(find.textContaining('Docs', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('Could not open this link.'), findsOneWidget);
  });

  testWidgets(
      'desktop MessageView provides accessible Copy and Activity buttons',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    const markdown = 'Answer with `code`';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MessageView(
          text: markdown,
          user: false,
          activityText: 'Tool activity: search',
        ),
      ),
    ));
    expect(find.byTooltip('Copy message'), findsOneWidget);
    expect(find.byTooltip('Show activity'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy message'));
    await tester.pumpAndSettle();
    expect(copied, markdown);
    expect(find.text('Copied'), findsOneWidget);

    await tester.tap(find.byTooltip('Show activity'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tool activity: search'), findsOneWidget);
    expect(find.byTooltip('Hide activity'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
      'BusyThinking hides frozen elapsed timer under reduced motion and desktop MessageView fits narrow 2x text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          disableAnimations: true,
          textScaler: TextScaler.linear(2),
        ),
        child: Scaffold(
          body: Column(
            children: [
              BusyThinking(busy: true, random: Random(7)),
              const MessageView(
                text:
                    'A narrow desktop reply with a [link](https://example.com)',
                user: false,
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const Key('thinking-elapsed')), findsNothing);
    expect(find.byTooltip('Copy message'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
