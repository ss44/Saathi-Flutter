import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_home.dart';

void main() {
  testWidgets('long-press copies a response immediately without a second tap',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'];
      }
      return null;
    });
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: MessageView(text: 'A **useful** response.', user: false))));
    await tester.longPress(find.byType(MessageView));
    await tester.pumpAndSettle();
    expect(copied, 'A **useful** response.');
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Copy message'), findsNothing);
  });
}
