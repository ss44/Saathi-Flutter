import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/main.dart';

void main() {
  testWidgets('shows the conversation shell', (tester) async {
    await tester.pumpWidget(const IrisApp());

    expect(find.text('Iris'), findsOneWidget);
    expect(find.text('Your conversation starts here'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('Connection settings'), findsOneWidget);
  });
}
