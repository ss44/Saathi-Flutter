import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';

void main() {
  testWidgets('native host never appears as a direct-model connection',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await controller.load();
    await controller.addConnection({
      'id': 'native',
      'name': 'Native host only',
      'type': 'hermesGateway',
      'url': 'wss://trusted.example/api/ws'
    }, '');
    await tester
        .pumpWidget(MaterialApp(home: NewChatPage(controller: controller)));
    expect(find.text('Native host only'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
      'actual drawer exposes explicit trusted host import with no default trust',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final controller = ChatController(store);
    await controller.load();
    await tester
        .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hermes Desktop / CLI'));
    await tester.pumpAndSettle();
    expect(find.text('Trusted WSS address'), findsOneWidget);
    expect(find.text('Host-issued invite JSON'), findsOneWidget);
    expect(find.text('Trust this host and connect'), findsOneWidget);
    final field =
        tester.widget<TextField>(find.byKey(const Key('gateway-trusted-url')));
    expect(field.controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
