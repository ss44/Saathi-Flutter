import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/canonical_connection.dart';
import 'gateway/canonical_combined_controller_test.dart' show NativeHost;
import 'runtime_flow_test.dart' show runtimeCapabilities;

class DelayedHistoryStore extends SaathiStore {
  DelayedHistoryStore({required super.preferences, required super.secrets});
  Completer<void>? gate;
  bool started = false;
  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    if (gate != null) {
      started = true;
      await gate!.future;
    }
    await super.saveChats(chats);
  }
}

Future<void> until(WidgetTester t, bool Function() ready, String label) async {
  for (var i = 0; i < 300; i++) {
    if (ready()) return;
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 10));
  }
  fail('Timeout: $label');
}

void main() {
  test(
      'reopening idle original API session reconciles externally added history',
      () async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    var externalReply = false;
    final client = MockClient((r) async {
      requests.add(r);
      if (r.url.path.endsWith('/capabilities')) {
        return http.Response(jsonEncode(runtimeCapabilities), 200);
      }
      expect(r.method, 'GET');
      expect(r.url.path, '/api/sessions/external/messages');
      return http.Response(
          jsonEncode({
            'session_id': 'external',
            'data': [
              {'id': 1, 'role': 'user', 'content': 'Original input'},
              {'id': 2, 'role': 'assistant', 'content': 'Original answer'},
              if (externalReply)
                {
                  'id': 3,
                  'role': 'assistant',
                  'content': 'Other client authoritative reply'
                },
            ],
            'pagination': {
              'offset': 0,
              'limit': 100,
              'returned': externalReply ? 3 : 2,
              'order': 'oldest'
            },
          }),
          200);
    });
    final c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()),
        coreFactory: () => SaathiCore(client: client),
        runClientFactory: (root, key) => RunClient(root, key, client: client));
    addTearDown(() {
      c.dispose();
      client.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'original',
      'name': 'Original server',
      'type': 'hermes',
      'url': 'https://original.example'
    }, 'fixture');
    final connection = c.connections.single;
    final remote = RemoteSession(
        {'id': 'external', 'source': 'api_server', 'title': 'External'});
    await c.continueRemote(connection, remote);
    final original = c.current!;
    expect(c.currentRun, isNull);
    expect(c.runPending, isFalse);
    externalReply = true;
    await c.continueRemote(connection, remote);
    expect(c.current, same(original));
    expect(c.sessions, [original]);
    expect(
        requests.where((r) => r.url.path.endsWith('/messages')), hasLength(2));
    expect(
        requests.every(
            (r) => r.method == 'GET' && r.url.host == 'original.example'),
        isTrue);
    expect(original.messages.map((m) => m.content), [
      'Original input',
      'Original answer',
      'Other client authoritative reply'
    ]);
  });

  testWidgets(
      'native attach completion cannot pop routes after its page was dismissed',
      (t) async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    final host = NativeHost();
    final store = DelayedHistoryStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final c = ChatController(store);
    await t.runAsync(() async {
      await host.start();
      await c.load();
    });
    final nav = GlobalKey<NavigatorState>();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(
        navigatorKey: nav, home: const Scaffold(body: Text('Home sentinel'))));
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Settings sentinel')))));
    await t.pumpAndSettle();
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => CanonicalConnectionPage(controller: c))));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('gateway-trusted-url')), host.url);
    await t.enterText(
        find.widgetWithText(TextField, 'Host-issued invite JSON'), host.invite);
    final scroll = find
        .descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    await t.scrollUntilVisible(find.text('Trust this host and connect'), 150,
        scrollable: scroll);
    await t.tap(find.text('Trust this host and connect'));
    await until(
        t,
        () =>
            host.requests.where((r) => r['method'] == 'session.list').length ==
                2 &&
            find.text('Trust this host and connect').evaluate().isNotEmpty,
        'connected list');
    await t.scrollUntilVisible(find.text('Native A'), 150, scrollable: scroll);
    await t.pumpAndSettle();
    store.gate = Completer<void>();
    await t.tap(find.text('Native A'));
    await until(t, () => store.started, 'attached history save');
    expect(c.current!.remoteSessionId, 'chat');
    expect(host.requests.where((r) => r['method'] == 'prompt.submit'), isEmpty);
    nav.currentState!.pop();
    await t.pump(const Duration(milliseconds: 1));
    expect(find.byType(CanonicalConnectionPage, skipOffstage: false),
        findsOneWidget,
        reason: 'page remains mounted during reverse transition');
    store.gate!.complete();
    await until(t, () => c.canonical?.awaitingSnapshotSave == false,
        'authoritative snapshot saved');
    await t.pump();
    await t.pumpAndSettle();
    final settingsRemain = find.text('Settings sentinel').evaluate().length;
    final submitCount =
        host.requests.where((r) => r['method'] == 'prompt.submit').length;
    await t.pumpWidget(const SizedBox());
    c.dispose();
    await t.runAsync(host.close);
    // Suspension closes the real socket asynchronously. Drain that handshake
    // before the test binding checks its timer invariants.
    for (var i = 0; i < 10; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 10));
    }
    await t.pump(const Duration(seconds: 6));
    expect(submitCount, 0);
    expect(settingsRemain, 1,
        reason:
            'late native attach must not pop the underlying Settings route');
  });
}
