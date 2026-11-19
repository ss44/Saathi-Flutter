import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder appBarText(String text) =>
    find.descendant(of: find.byType(AppBar), matching: find.text(text));

Future<ChatController> controller({CoreFactory? coreFactory}) async {
  SharedPreferences.setMockInitialValues({});
  final c = ChatController(
      SaathiStore(
          preferences: await SharedPreferences.getInstance(),
          secrets: MemorySecrets()),
      coreFactory: coreFactory);
  await c.load();
  return c;
}

ChatSession session(String id, String title) => ChatSession(
    id: id,
    connectionId: 'source',
    model: 'model',
    messages: [ChatMessage(role: 'user', content: title)]);

void main() {
  testWidgets('server switches keep selected title when old history finishes',
      (tester) async {
    final pending = Completer<http.Response>();
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/v1/capabilities') {
        return http.Response('{}', 200);
      }
      if (request.url.path == '/api/sessions') {
        return http.Response(
            '{"data":[{"id":"a","title":"Server A"},'
            '{"id":"b","title":"Server B"}],"has_more":false}',
            200);
      }
      if (request.url.path == '/api/sessions/a/messages') return pending.future;
      if (request.url.path == '/api/sessions/b/messages') {
        return http.Response('{"data":[],"session_id":"b"}', 200);
      }
      throw StateError('Unexpected request');
    });
    final c = await controller(coreFactory: () => SaathiCore(client: client));
    c.connections.add({
      'id': 'source',
      'name': 'Server',
      'type': 'hermes',
      'url': 'https://example.test'
    });
    final local = session('local', 'Local question');
    c.sessions.add(local);
    c.select(local);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 20 && find.text('Server A').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text('Server A'), findsOneWidget,
        reason: 'Requests: ${requests.map((r) => r.url)}; '
            'visible: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data)}');
    await tester.tap(find.text('Server A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(appBarText('Server A'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(requests.where((r) => r.url.path.endsWith('/a/messages')),
        hasLength(1));
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(appBarText(local.title), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server B'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(appBarText('Server B'), findsOneWidget);
    pending.complete(http.Response(
        '{"data":[{"role":"assistant","content":"Old server text"}],'
        '"session_id":"a","title":"Stale server title"}',
        200));
    await tester.pumpAndSettle();
    expect(appBarText('Server B'), findsOneWidget);
    expect(appBarText('Server A'), findsNothing);
    expect(find.text('Old server text'), findsNothing);
    expect(find.text('Stale server title'), findsNothing);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    expect(c.current, same(local));
    expect(c.sessions, [local]);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(appBarText(local.title), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    client.close();
  });

  for (final width in [360.0, 390.0]) {
    testWidgets('long server title preserves back navigation at $width 2x',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = MockClient((_) async => http.Response('{"data":[]}', 200));
      final c = await controller(coreFactory: () => SaathiCore(client: client));
      final connection = <String, dynamic>{
        'id': 'source',
        'name': 'Server',
        'type': 'hermes',
        'url': 'https://example.test'
      };
      c.connections.add(connection);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!),
          home: ChatHome(controller: c)));
      final title = 'Long server conversation title ' * 20;
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => RemoteHistoryPage(
              controller: c,
              connection: connection,
              session: RemoteSession({'id': 'remote', 'title': title})))));
      await tester.pumpAndSettle();
      final text = appBarText(title);
      expect(tester.widget<Text>(text).maxLines, 1);
      expect(tester.widget<Text>(text).overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      final back = find.byTooltip('Back');
      expect(back.hitTestable(), findsOneWidget);
      expect(tester.getRect(text).left,
          greaterThanOrEqualTo(tester.getRect(back).right));
      expect(tester.getRect(text).right, lessThanOrEqualTo(width));
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byType(RemoteHistoryPage), findsNothing);
      expect(appBarText('New conversation'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      client.close();
    });
  }

  testWidgets('blank server title uses New conversation', (tester) async {
    final client = MockClient((_) async => http.Response('{"data":[]}', 200));
    final c = await controller(coreFactory: () => SaathiCore(client: client));
    final connection = <String, dynamic>{
      'id': 'source',
      'name': 'Server',
      'type': 'hermes',
      'url': 'https://example.test'
    };
    c.connections.add(connection);
    await tester.pumpWidget(MaterialApp(
        home: RemoteHistoryPage(
            controller: c,
            connection: connection,
            session: RemoteSession({'id': 'remote', 'title': ' \t '}))));
    expect(appBarText('New conversation'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    client.close();
  });

  for (final width in [360.0, 390.0]) {
    testWidgets('long local title preserves navigation/actions at $width 2x',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.reset);
      final c = await controller();
      final chat = session('long', 'A long conversation title ' * 20);
      c.sessions.add(chat);
      c.select(chat);
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!),
          home: ChatHome(controller: c)));
      final title = appBarText(chat.title);
      expect(tester.widget<Text>(title).maxLines, 1);
      expect(tester.widget<Text>(title).overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      final titleRect = tester.getRect(title);
      final navigation = find.byTooltip('Open navigation menu');
      final actions = ['New conversation', 'Settings', 'Delete conversation'];
      expect(titleRect.left,
          greaterThanOrEqualTo(tester.getRect(navigation).right));
      for (final tooltip in actions) {
        final action = find.byTooltip(tooltip);
        expect(action.hitTestable(), findsOneWidget);
        final rect = tester.getRect(action);
        expect(rect.right, lessThanOrEqualTo(width));
        expect(titleRect.right, lessThanOrEqualTo(rect.left));
      }
      await tester.tap(navigation);
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets('new, empty and blank local titles use New conversation',
      (tester) async {
    final c = await controller();
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    expect(appBarText('New conversation'), findsOneWidget);
    final empty =
        ChatSession(id: 'empty', connectionId: 'source', model: 'model');
    final blank = session('blank', ' \n\t ');
    c.sessions.addAll([empty, blank]);
    for (final chat in [empty, blank]) {
      c.select(chat);
      await tester.pump();
      expect(appBarText('New conversation'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('main title follows drawer selection and current display title',
      (tester) async {
    var requests = 0;
    final c = await controller(coreFactory: () {
      requests++;
      throw StateError('Title changes must not fetch anything');
    });
    final first = session('first', 'First question');
    final second = session('second', 'Second question');
    c.sessions.addAll([first, second]);
    c.select(first);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    expect(appBarText(first.title), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(Drawer), matching: find.text(second.title)));
    await tester.pump();
    expect(appBarText(second.title), findsOneWidget);
    expect(appBarText(first.title), findsNothing);
    await tester.pumpAndSettle();
    // There is no rename UI yet. Use the existing display-title source and
    // notification contract rather than inventing a separate title cache.
    second.messages[0] = ChatMessage(role: 'user', content: 'Updated question');
    c.notifyListeners();
    await tester.pump();
    expect(appBarText('Updated question'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(Drawer), matching: find.text('Updated question')),
        findsOneWidget);
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
