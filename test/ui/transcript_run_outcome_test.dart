import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/ui/chat_controller.dart';
import '../agent_run_controller_safety_test.dart' show ReconcileSecrets;
import '../agent_run_hardening_test.dart' show setup, FailingHistory;
import '../agent_runs_test.dart' show capabilities;

void main() {
  for (final failure in ['history', 'journal', 'none']) {
    test('empty Runs answer retains its outcome after $failure storage retry',
        () async {
      final secrets = ReconcileSecrets();
      var posts = 0;
      var requests = 0;
      var complete = false;
      Future<http.Response> handler(http.Request request) async {
        requests++;
        if (request.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (request.method == 'POST') {
          posts++;
          return http.Response('{"run_id":"r","status":"started"}', 202);
        }
        return http.Response(
            jsonEncode({
              'run_id': 'r',
              'status': complete ? 'completed' : 'running',
              if (complete) 'output': ' \n ',
            }),
            200);
      }

      final initial = await setup(secrets, handler);
      final store = FailingHistory(initial.store)..fail = false;
      initial.dispose();
      final c = ChatController(store,
          runClientFactory: (root, key) =>
              RunClient(root, key, client: MockClient(handler)));
      addTearDown(c.dispose);
      await c.load();
      var alerts = 0;
      c.onReplyReceived = (_) => alerts++;
      expect(await c.send('first'), isTrue);
      store.fail = failure == 'history';
      secrets.failCommit = failure == 'journal';
      complete = true;
      await c.checkRunStatus();
      expect(c.unsavedChanges, failure != 'none');
      final requestCount = requests;
      if (failure != 'none') {
        await c.retrySave();
        expect(c.unsavedChanges, isTrue);
      }
      store.fail = false;
      secrets.failCommit = false;
      await c.retrySave();
      expect(requests, requestCount, reason: 'Saving does not query or resend');
      expect(c.unsavedChanges, isFalse);
      expect(c.runPending, isFalse);
      expect(c.current!.messages, hasLength(2));
      expect(c.current!.messages.last.content, ' \n ');
      expect(
          c.current!.messages.last.metadata['authoritativeCompletion'], isNull);
      expect(
          c.organization.entry(c.identityOf(c.current!)).completions, isEmpty);
      expect(c.error, contains('without a text response'));
      expect(alerts, 0,
          reason: 'An empty outcome is not a completed reply alert');
      final original = c.current!;
      final other = ChatSession(id: 'other', connectionId: 'h', model: 'model');
      c.sessions.add(other);
      c.select(other);
      expect(c.error, isNull);
      c.select(original);
      expect(c.error, contains('without a text response'));
      expect(posts, 1);
    });
  }
}
