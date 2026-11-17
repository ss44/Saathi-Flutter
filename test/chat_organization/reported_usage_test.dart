import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/chat_organization/reported_usage.dart';

void main() {
  test('reported usage permits only bounded supplied token integers', () {
    final usage = ReportedUsage.fromMetadata({
      'promptTokens': 12,
      'completionTokens': 3,
      'totalTokens': 15,
      'apiKey': 'never persist',
      'runtime': {'secret': 'no'}
    });
    expect(usage.toMetadata(),
        {'promptTokens': 12, 'completionTokens': 3, 'totalTokens': 15});
    expect(
        ReportedUsage.fromMetadata({
          'promptTokens': '12',
          'completionTokens': -1,
          'totalTokens': 1.5
        }).available,
        isFalse);
    expect(
        ReportedUsage.fromMetadata({'totalTokens': 999999999999999999})
            .available,
        isFalse);
  });
  testWidgets(
      'small expandable usage hides unsupported and never invents a percent or price',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReportedUsageLine(
                usage: ReportedUsage.fromMetadata(const {})))));
    expect(find.byType(ExpansionTile), findsNothing);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReportedUsageLine(
                usage: ReportedUsage.fromMetadata({'promptTokens': 12}),
                context: const ConversationContextMetadata(
                    serverOwned: true, retainedMessages: 20)))));
    expect(find.text('Reported tokens · Input 12'), findsOneWidget);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('Output unavailable'), findsOneWidget);
    expect(find.textContaining('Server-owned context'), findsOneWidget);
    expect(find.textContaining('model context limit'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('\$'), findsNothing);
  });
}
