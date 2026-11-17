import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:saathi/chat_organization/organization_widgets.dart';
import 'runtime_flow_test.dart'
    show RuntimeFixture, RealHttp, runtimeCapabilities;
import 'organization_controller_integration_test.dart'
    show ControlledOrganizationStorage;

class OrganizationNativeFixture extends RuntimeFixture {
  @override
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/capabilities')) {
        request.response.write(jsonEncode(runtimeCapabilities));
      } else if (request.method == 'POST') {
        final input = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        inputs.add(input);
        submissions++;
        statusSessionId = input['session_id'] as String;
        request.response.statusCode = 202;
        request.response.write('{"run_id":"run_fixture","status":"running"}');
      } else {
        request.response.write(jsonEncode({
          'run_id': 'run_fixture',
          'session_id': statusSessionId,
          'status': completed ? 'completed' : 'running',
          if (completed) 'output': terminalOutput
        }));
      }
      await request.response.close();
    });
  }
}

Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('empty native terminal output is not an unread answer', () async {
    final fixture = OrganizationNativeFixture()..terminalOutput = '';
    final client = HttpOverrides.runWithHttpOverrides(
        () => IOClient(HttpClient()), RealHttp());
    await fixture.start();
    SharedPreferences.setMockInitialValues({});
    final c = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets()),
        coreFactory: () => SaathiCore(client: client),
        runClientFactory: (root, key) => RunClient(root, key, client: client));
    addTearDown(() async {
      c.dispose();
      client.close();
      await fixture.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'name': 'Native',
      'type': 'hermes',
      'url': 'http://127.0.0.1:${fixture.server.port}'
    }, 'fixture');
    await c.newSession(c.connections.single, 'model', '');
    await c.send('hello');
    fixture.completed = true;
    await c.checkRunStatus();
    expect(c.runPending, isFalse);
    expect(c.organization.entry(c.identityOf(c.current!)).completions, isEmpty);
  });

  test(
      'real native HTTP queue stays admitted through metadata failure, archive keeps observing, storage retry wakes existing FIFO',
      () async {
    final fixture = OrganizationNativeFixture();
    final client = HttpOverrides.runWithHttpOverrides(
        () => IOClient(HttpClient()), RealHttp());
    await fixture.start();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = ControlledOrganizationStorage(prefs);
    final c = ChatController(
        SaathiStore(preferences: prefs, secrets: MemorySecrets()),
        organizationStorage: storage,
        coreFactory: () => SaathiCore(client: client),
        runClientFactory: (root, key) => RunClient(root, key, client: client));
    addTearDown(() async {
      c.dispose();
      client.close();
      await fixture.close();
    });
    await c.load();
    await c.addConnection({
      'id': 'native',
      'name': 'Native',
      'type': 'hermes',
      'url': 'http://127.0.0.1:${fixture.server.port}'
    }, 'fixture');
    await c.newSession(c.connections.single, 'model', 'captured native role');
    final session = c.current!;
    final identity = c.identityOf(session);
    expect(c.personaPolicy(identity), PersonaEditPolicy.serverOwned);
    expect(await c.send('first input'), isTrue);
    fixture.statusSessionId = c.currentRun!.sessionId;
    expect(c.organization.entry(identity).completions,
        isEmpty); // 202 is not a reply
    expect(c.workState(session), ConversationWorkState.working);
    expect(c.submit('second input'), isTrue);
    expect(fixture.submissions, 1);
    await c.organization.setArchived(identity, true);
    expect(c.sessions, contains(session));
    storage.fail = true;
    fixture.completed = true;
    await c.checkRunStatus();
    expect(session.messages.last.content, 'Authoritative final response');
    final marker = session.messages.last.id!;
    expect(c.organization.entry(identity).completions, isEmpty);
    expect(c.organization.hasUnsavedChanges, isTrue);
    expect(fixture.submissions, 1);
    expect(c.outbox.single.text, 'second input');
    storage.fail = false;
    await c.retryOrganizationSave();
    await eventually(() => fixture.submissions == 2 && !c.busy);
    expect(
        c.organization.entry(identity).completions.containsKey(marker), isTrue);
    expect(c.organization.entry(identity).archived, isTrue);
    expect(fixture.inputs.first['instructions'], 'captured native role');
    final journal = await c.store.secrets.read('run.v1.${session.id}');
    expect(
        jsonDecode(journal!)['capturedInstructions'], 'captured native role');
    expect(jsonDecode(journal)['personaRevision'], 0);
    expect(fixture.inputs.last['input'], 'second input');
    expect(fixture.inputs.last.containsKey('conversation_history'), isFalse);
  });
}
