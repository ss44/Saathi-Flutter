import 'dart:async';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/dashboard/dashboard_store.dart';
import 'package:saathi/dashboard/dashboard_pages.dart';

void main() {
  testWidgets('failed stored scope never displays selectable live rows',
      (tester) async {
    final gateway = _ScopeGateway();
    await tester
        .pumpWidget(MaterialApp(home: DashboardSessionsPage(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('Live row'), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('Session list unavailable'), findsOneWidget);
    expect(find.text('Live row'), findsNothing);
  });
  testWidgets('leaving login during attempt safely disposes password',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = _PendingStore(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
            body: TextButton(
                onPressed: () => navigator.currentState!.push(
                    MaterialPageRoute<void>(
                        builder: (_) => DashboardLoginPage(store: store))),
                child: const Text('Open login')))));
    await tester.tap(find.text('Open login'));
    await tester.pumpAndSettle();
    for (final field in find.byType(TextFormField).evaluate().toList()) {
      await tester.enterText(find.byWidget(field.widget), 'fixture');
    }
    await tester.scrollUntilVisible(find.text('Sign in securely'), 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Sign in securely'));
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(store.cancellation?.isCancelled, isTrue);
    store.result.completeError(StateError('private'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    store.close();
  });
  testWidgets(
      'dashboard login fits 360px 2x with keyboard, password stays private',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = DashboardStore(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets()));
    addTearDown(store.close);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(360, 800),
                textScaler: TextScaler.linear(2),
                viewInsets: EdgeInsets.only(bottom: 280)),
            child: DashboardLoginPage(store: store))));
    await tester.scrollUntilVisible(find.text('Dashboard URL'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Dashboard URL'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Username'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Username'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Password'), 150,
        scrollable: find.byType(Scrollable).first);
    final password =
        find.byWidgetPredicate((w) => w is EditableText && w.obscureText);
    expect(password, findsOneWidget);
    await tester.scrollUntilVisible(find.text('Sign in securely'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
}

class _ScopeGateway extends HermesGatewayClient {
  _ScopeGateway()
      : super(grantProvider: () async => throw StateError('unused'));
  @override
  Future<List<GatewaySession>> listSessions(
      {bool stored = false, int limit = 50}) async {
    if (stored) throw const GatewayException('unavailable');
    return [
      GatewaySession({'session_id': 'live', 'title': 'Live row'})
    ];
  }
}

class _PendingStore extends DashboardStore {
  _PendingStore(super.storage);
  final result = Completer<DashboardConnection>();
  DashboardLoginCancellation? cancellation;
  @override
  Future<DashboardConnection> signIn(
      {required String name,
      required String baseUrl,
      required String username,
      required String password,
      DashboardLoginCancellation? cancellation}) {
    this.cancellation = cancellation;
    return result.future;
  }
}
