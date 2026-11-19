import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/canonical_connection.dart';

void main() {
  testWidgets('native host opens gateway setup instead of direct-model setup',
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
    expect(find.text('Native host only'), findsOneWidget);
    expect(find.text('Model ID'), findsNothing);
    expect(find.text('Discover models'), findsNothing);
    await tester.tap(find.text('Open Hermes gateway'));
    await tester.pumpAndSettle();
    expect(find.byType(CanonicalConnectionPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('new Hermes connections use gateway, not REST credentials',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await controller.load();
    await tester.pumpWidget(
        MaterialApp(home: AddConnectionPage(controller: controller)));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hermes').last);
    await tester.pumpAndSettle();
    expect(find.byType(CanonicalConnectionPage), findsOneWidget);
    expect(find.text('API key / token'), findsNothing);
    expect(find.text('API base URL'), findsNothing);
    expect(controller.connections, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('saved native chat offers original-session reconnect',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = ChatController(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    await controller.load();
    await controller.addConnection({
      'id': 'native',
      'name': 'My Hermes',
      'type': 'hermesGateway',
      'url': 'wss://trusted.example/api/ws'
    }, '');
    final chat = ChatSession(
        id: 'saved',
        connectionId: 'native',
        model: 'Hermes',
        remoteSessionId: 'original',
        canonicalProfileId: 'profile');
    controller.sessions.add(chat);
    controller.select(chat);
    await tester
        .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.textContaining('This connection was removed'), findsNothing);
    await tester.tap(find.text('Reconnect Hermes'));
    await tester.pumpAndSettle();
    expect(find.byType(CanonicalConnectionPage), findsOneWidget);
    expect(find.textContaining('original conversation'), findsOneWidget);
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
    await tester.tap(find.text('Hermes gateway'));
    await tester.pumpAndSettle();
    expect(find.text('Trusted gateway address'), findsOneWidget);
    expect(find.text('Host-issued invite JSON'), findsOneWidget);
    expect(find.text('Trust this host and connect'), findsOneWidget);
    final field =
        tester.widget<TextField>(find.byKey(const Key('gateway-trusted-url')));
    expect(field.controller!.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
