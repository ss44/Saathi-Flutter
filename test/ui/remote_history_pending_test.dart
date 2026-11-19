import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart' as core;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_history_test_driver.dart';

class _HistorySecrets extends MemorySecrets {
  Completer<String?>? gate;
  bool started = false;
  @override
  Future<String?> read(String id) {
    final pending = gate;
    if (pending == null) return super.read(id);
    started = true;
    return pending.future;
  }
}

class _HistoryCore extends core.SaathiCore {
  _HistoryCore(http.Client client) : super(client: client);
  bool closed = false, settled = false;
  @override
  Future<core.RemoteHistoryPage> loadRemoteHistory(
      String providerId, String sessionId,
      {int limit = 100, int offset = 0, bool includeCompacted = false}) async {
    try {
      return await super.loadRemoteHistory(providerId, sessionId,
          limit: limit, offset: offset, includeCompacted: includeCompacted);
    } finally {
      settled = true;
    }
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  for (final phase in ['secret', 'response']) {
    for (final action in ['dispose', 'source round trip', 'lifecycle']) {
      testWidgets('pending history $phase rejects $action and closes its core',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        final secrets = _HistorySecrets();
        final response = Completer<http.Response>();
        final requests = <http.Request>[];
        final client = MockClient((request) {
          requests.add(request);
          return response.future;
        });
        final historyCore = _HistoryCore(client);
        final c = ChatController(
            SaathiStore(
                preferences: await SharedPreferences.getInstance(),
                secrets: secrets),
            coreFactory: () => historyCore);
        await c.load();
        await c.addConnection({
          'id': 'original',
          'name': 'Original source',
          'type': 'hermes',
          'url': 'https://original.example',
        }, 'fixture');
        final connection = c.connections.single;
        final original = ChatSession(
            id: 'original-local',
            connectionId: 'original',
            model: 'original-model',
            messages: [
              core.ChatMessage(role: 'user', content: 'Original question')
            ]);
        c.sessions.add(original);
        c.select(original);
        if (phase == 'secret') secrets.gate = Completer<String?>();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Original route'))));
        unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => RemoteHistoryPage(
                controller: c,
                connection: connection,
                session: core.RemoteSession({
                  'id': 'external',
                  'title': 'Pending external',
                  'source': 'api_server',
                })))));
        await tester.pump();
        await waitForHistoryState(
            tester,
            () => phase == 'secret' ? secrets.started : requests.isNotEmpty,
            'pending $phase');
        await tester.pump(const Duration(milliseconds: 400));
        expect(historyCore.closed, isFalse);
        if (action == 'dispose') {
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(RemoteHistoryPage), findsNothing);
          expect(find.text('Original route'), findsOneWidget);
        } else if (action == 'source round trip') {
          c.connections[0] = {...connection};
          c.notifyListeners();
          c.connections[0] = connection;
          c.notifyListeners();
          await tester.pump();
        } else {
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
            await tester.pump();
          }
        }
        if (phase == 'response') expect(historyCore.closed, isTrue);
        secrets.gate?.complete('fixture');
        response.complete(http.Response(
            '{"session_id":"external","data":[{"role":"assistant",'
            '"content":"Stale external answer"}],"pagination":{"has_more":false}}',
            200));
        await waitForHistoryState(
            tester,
            () =>
                historyCore.closed &&
                (phase == 'secret' || historyCore.settled),
            'revoked history cleanup');
        await tester.pump();
        expect(requests, hasLength(phase == 'secret' ? 0 : 1));
        for (final request in requests) {
          expect(request.method, 'GET');
          expect(request.url.host, 'original.example');
          expect(request.url.path, '/api/sessions/external/messages');
        }
        expect(c.current, same(original));
        expect(c.sessions, [original]);
        expect(c.connections.single, same(connection));
        expect(original.model, 'original-model');
        expect(original.remoteSessionId, isNull);
        expect(original.messages.single.content, 'Original question');
        expect(c.attachingRemote, isFalse);
        expect(find.text('Stale external answer'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        client.close();
      });
    }
  }
}
