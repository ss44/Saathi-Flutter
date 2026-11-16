import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/main.dart';
import 'package:saathi/storage/saathi_store.dart';

Future<SaathiStore> localStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets());
  await store.saveConnection({
    'id': 'local',
    'name': 'Direct model',
    'type': 'openai',
    'url': 'https://direct.test'
  }, apiKey: 'fixture-key');
  await store.saveChats([
    {
      'id': 'first',
      'connectionId': 'local',
      'model': 'fixture',
      'messages': [
        {'role': 'user', 'content': 'Local first'}
      ]
    },
    {
      'id': 'second',
      'connectionId': 'local',
      'model': 'fixture',
      'messages': [
        {'role': 'user', 'content': 'Local second'}
      ]
    },
  ]);
  return store;
}

void main() {
  testWidgets(
      'keyboard opens the drawer and system Back closes it without leaving chat',
      (t) async {
    final store = await localStore();
    await t.pumpWidget(SaathiApp(store: store));
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(t.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
        isTrue);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(t.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
        isFalse);
    expect(find.byKey(const Key('composer')), findsOneWidget);
  });

  testWidgets('ordinary model drawer makes no server-history requests',
      (t) async {
    final store = await localStore();
    final requests = <http.Request>[];
    final client = MockClient((r) async {
      requests.add(r);
      return http.Response('{}', 500);
    });
    await t.pumpWidget(
        SaathiApp(store: store, coreFactory: () => SaathiCore(client: client)));
    await t.pumpAndSettle();
    await t.dragFrom(const Offset(40, 300), const Offset(350, 0));
    await t.pumpAndSettle();
    expect(find.text('On this device'), findsOneWidget);
    expect(requests, isEmpty);
  });

  for (final width in [390.0, 360.0]) {
    testWidgets(
        'server failure leaves local selection usable with remote notes at $width',
        (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 1000);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      final store = await localStore();
      for (final id in ['good', 'bad']) {
        await store.saveConnection({
          'id': id,
          'name': '$id Hermes',
          'type': 'hermes',
          'url': 'https://$id.test'
        }, apiKey: 'fixture-key');
      }
      final requests = <http.Request>[];
      final client = MockClient((r) async {
        requests.add(r);
        if (r.url.host == 'bad.test') {
          return http.Response('PRIVATE fixture-key', 500);
        }
        if (r.url.path == '/v1/capabilities') return http.Response('{}', 200);
        if (r.url.path == '/api/sessions') {
          return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'remote', 'title': 'Remote first'}
                ],
                'has_more': false
              }),
              200);
        }
        return http.Response(
            jsonEncode({
              'session_id': 'remote',
              'data': [
                {'role': 'assistant', 'content': 'Remote shown reply'}
              ],
              'pagination': {'has_more': false}
            }),
            200);
      });
      await t.pumpWidget(SaathiApp(
          store: store,
          coreFactory: () => SaathiCore(client: client),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(width == 360 ? 2 : 1)),
              child: child!)));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        await t.dragFrom(const Offset(40, 300), const Offset(350, 0));
        await t.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await t.pumpAndSettle();
      final drawerScroll = find.descendant(
          of: find.byType(Drawer), matching: find.byType(Scrollable));
      await t.scrollUntilVisible(find.text('Try again'), 200,
          scrollable: drawerScroll);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(find.text('Local first'), -200,
          scrollable: drawerScroll);
      await t.tap(find.text('Local first'));
      await t.pumpAndSettle();
      expect(find.text('Local first'), findsOneWidget);
      await t.tap(find.byTooltip('Open navigation menu'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Remote first'), 150,
          scrollable: find.descendant(
              of: find.byType(Drawer), matching: find.byType(Scrollable)));
      await t.ensureVisible(find.text('Remote first'));
      await t.pumpAndSettle();
      expect(find.text('Remote first').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        await t.tap(find.text('Remote first'));
        await t.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Remote shown reply'), 200,
          scrollable: find.byType(Scrollable).last);
      await t.ensureVisible(find.text('Remote shown reply'));
      expect(find.text('Remote shown reply'), findsOneWidget);
      expect(find.byKey(const Key('composer')), findsNothing);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(t.takeException(), isNull);
    });
  }
}
