import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:saathi/storage/saathi_store.dart';

class DelayedSecrets extends MemorySecrets {
  final pending = Completer<String?>();
  @override
  Future<String?> read(String id) => pending.future;
}

class TrackedCore extends SaathiCore {
  TrackedCore(http.Client client) : super(client: client);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  for (final action in ['dispose', 'replace']) {
    testWidgets('history does not request after delayed key and $action',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'saathi.connections.v1':
            '[{"id":"h","name":"Home","type":"hermes","url":"https://example.test"}]',
      });
      final secrets = DelayedSecrets();
      var requests = 0;
      final client = MockClient((r) async {
        requests++;
        return http.Response('{"data":[]}', 200);
      });
      final core = TrackedCore(client);
      final c = ChatController(
          SaathiStore(
              preferences: await SharedPreferences.getInstance(),
              secrets: secrets),
          coreFactory: () => core);
      final connection = <String, dynamic>{
        'id': 'h',
        'name': 'Home',
        'type': 'hermes',
        'url': 'https://example.test'
      };
      c.connections.add(connection);
      await tester.pumpWidget(MaterialApp(
          home: RemoteHistoryPage(
              controller: c,
              connection: connection,
              session: RemoteSession({'id': 's', 'title': 'Chat'}))));
      await tester.pump();
      if (action == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      } else {
        c.connections[0] = {...connection};
        c.notifyListeners();
      }
      secrets.pending.complete('test');
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(core.closed, isTrue);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
  testWidgets('history drops stale content when connection is replaced',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()),
        coreFactory: () => SaathiCore(
            client: MockClient((r) async => http.Response(
                '{"data":[{"role":"assistant","content":"Old secret history"}],"pagination":{"has_more":false}}',
                200))));
    final connection = <String, dynamic>{
      'id': 'h',
      'name': 'Home',
      'type': 'hermes',
      'url': 'https://example.test'
    };
    c.connections.add(connection);
    await tester.pumpWidget(MaterialApp(
        home: RemoteHistoryPage(
            controller: c,
            connection: connection,
            session: RemoteSession({'id': 's', 'title': 'Chat'}))));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Old secret history'), findsOneWidget);
    c.connections[0] = {...connection};
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Old secret history'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  test('core closes on secret read failure', () async {
    SharedPreferences.setMockInitialValues({
      'saathi.connections.v1':
          '[{"id":"h","name":"Home","type":"hermes","url":"https://example.test"}]',
    });
    final secrets = DelayedSecrets();
    final client = MockClient((r) async => http.Response('{}', 200));
    final core = TrackedCore(client);
    final c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: secrets),
        coreFactory: () => core);
    final future = c.coreFor({
      'id': 'h',
      'name': 'Home',
      'type': 'hermes',
      'url': 'https://example.test'
    });
    secrets.pending.completeError(StateError('private'));
    await expectLater(future, throwsStateError);
    expect(core.closed, isTrue);
    c.dispose();
  });
}
