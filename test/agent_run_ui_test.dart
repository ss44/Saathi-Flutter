import 'package:flutter/material.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

void main() {
  testWidgets('pending run exposes Reconnect', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final c = ChatController(store);
    await c.load();
    final connection = {
      'id': 'h',
      'name': 'Hermes',
      'type': 'hermes',
      'url': 'https://host'
    };
    await c.addConnection(connection, 'fixture');
    await c.newSession(connection, 'model', '');
    final client = RunClient('https://host', 'fixture');
    c.runs[c.current!.id] = await client.prepare(RunLedger(store.secrets),
        local: c.current!.id,
        input: 'pending',
        model: 'model',
        instructions: '',
        history: []);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    expect(find.text('Reconnect'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    client.close();
  });
}
