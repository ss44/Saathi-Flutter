import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'agent_run_controller_safety_test.dart'
    show ReconcileSecrets, DelayedSecrets;
import 'package:saathi/ui/chat_controller.dart';
import 'agent_run_hardening_test.dart' show FailingHistory;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'agent_run_hardening_test.dart' show setup, FailingJournal;
import 'agent_runs_test.dart' show capabilities;

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  for (final pause in ['background', 'switch']) {
    test('$pause pause survives authoritative native completion', () async {
      var posts = 0;
      var complete = false;
      final c = await setup(FailingJournal(), (r) async {
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          posts++;
          return http.Response(
              jsonEncode({'run_id': 'r$posts', 'status': 'started'}), 202);
        }
        return http.Response(
            jsonEncode({
              'run_id': r.url.path.split('/').last,
              'status': complete ? 'completed' : 'running',
              if (complete) 'output': 'actual'
            }),
            200);
      });
      addTearDown(c.dispose);
      final original = c.current!;
      c.submit('first');
      c.submit('second');
      await settle();
      if (pause == 'background') {
        c.setQueueBackground(true);
        c.setQueueBackground(false);
      } else {
        final other =
            ChatSession(id: 'other', connectionId: 'h', model: 'model');
        c.sessions.add(other);
        c.select(other);
        c.select(original);
      }
      complete = true;
      await c.checkRunStatus();
      await settle();
      expect(posts, 1);
      expect(c.canResumeQueue, true);
      c.resumeQueue();
      await settle();
      expect(posts, 2);
    });
  }
  for (final failure in ['history', 'journal']) {
    test(
        '$failure failure holds native followers until save and explicit Resume',
        () async {
      final secrets = ReconcileSecrets();
      var posts = 0;
      var complete = false;
      Future<http.Response> handler(http.Request r) async {
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          posts++;
          return http.Response(
              jsonEncode({'run_id': 'r$posts', 'status': 'started'}), 202);
        }
        return http.Response(
            jsonEncode({
              'run_id': r.url.path.split('/').last,
              'status': complete ? 'completed' : 'running',
              if (complete) 'output': 'actual'
            }),
            200);
      }

      final initial = await setup(secrets, handler);
      final store = FailingHistory(initial.store)..fail = false;
      initial.dispose();
      final c = ChatController(store,
          runClientFactory: (root, key) =>
              RunClient(root, key, client: MockClient(handler)));
      await c.load();
      addTearDown(c.dispose);
      c.submit('first');
      c.submit('second');
      c.submit('third');
      await settle();
      expect(posts, 1);
      if (failure == 'history') {
        store.fail = true;
      } else {
        secrets.failCommit = true;
      }
      complete = true;
      await c.checkRunStatus();
      expect(c.unsavedChanges, true);
      expect(c.queueStatus, isNotNull);
      expect(posts, 1);
      store.fail = false;
      secrets.failCommit = false;
      await c.retrySave();
      await settle();
      expect(posts, 1);
      expect(c.canResumeQueue, true);
      c.resumeQueue();
      await settle();
      expect(posts, 3);
    });
  }
  for (final state in ['unknown', 'failed', 'cancelled', 'interrupted']) {
    test('$state visibly pauses native followers', () async {
      var posts = 0;
      final c = await setup(FailingJournal(), (r) async {
        if (r.url.path.endsWith('capabilities')) {
          return http.Response(jsonEncode(capabilities), 200);
        }
        if (r.method == 'POST') {
          posts++;
          return http.Response('{"run_id":"r","status":"started"}', 202);
        }
        return http.Response(jsonEncode({'run_id': 'r', 'status': state}), 200);
      });
      addTearDown(c.dispose);
      c.submit('first');
      c.submit('second');
      c.submit('third');
      await settle();
      expect(posts, 1);
      expect(c.outbox.length, 2);
      expect(c.queueStatus, isNotNull);
      await c.retrySave();
      await settle();
      expect(posts, 1);
    });
  }
  for (final kind in ['background', 'switch', 'revision']) {
    test('$kind during native credential preparation cannot late-send',
        () async {
      final secrets = DelayedSecrets();
      var requests = 0;
      final c = await setup(secrets, (r) async {
        requests++;
        return http.Response(jsonEncode(capabilities), 200);
      });
      addTearDown(c.dispose);
      secrets.entered = Completer<void>();
      secrets.release = Completer<void>();
      c.submit('first');
      c.submit('second');
      await secrets.entered!.future;
      if (kind == 'background') c.setQueueBackground(true);
      if (kind == 'switch') {
        final other =
            ChatSession(id: 'other', connectionId: 'h', model: 'model');
        c.sessions.add(other);
        c.select(other);
      }
      if (kind == 'revision') c.connections[0] = {...c.connections[0]};
      secrets.release!.complete();
      await settle();
      expect(requests, 0);
      c.select(c.sessions.first);
      expect(c.queueStatus, isNotNull);
    });
  }
  test(
      'localhost POST202 running holds followers and completion releases same session',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var posts = 0;
    var completed = false;
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('capabilities')) {
        request.response.write(jsonEncode(capabilities));
      } else if (request.method == 'POST') {
        posts++;
        bodies.add(jsonDecode(body) as Map<String, dynamic>);
        request.response.statusCode = 202;
        request.response
            .write(jsonEncode({'run_id': 'r$posts', 'status': 'started'}));
      } else {
        request.response.write(jsonEncode({
          'run_id': request.uri.path.split('/').last,
          'status': completed ? 'completed' : 'running',
          if (completed) 'output': 'actual'
        }));
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final initial =
        await setup(FailingJournal(), (r) async => http.Response('{}', 500));
    await initial.updateConnection('h', {
      ...initial.connections.single,
      'url': 'http://127.0.0.1:${server.port}'
    });
    final connection = initial.connections.single;
    await initial.newSession(connection, 'model', '');
    final c = ChatController(initial.store);
    initial.dispose();
    await c.load();
    addTearDown(c.dispose);
    c.submit('first');
    c.submit('second');
    c.submit('third');
    for (var i = 0; i < 100 && (c.busy || posts == 0); i++) {
      await settle();
    }
    expect(posts, 1);
    expect(c.outbox.length, 2);
    completed = true;
    await c.checkRunStatus();
    for (var i = 0; i < 100 && (c.busy || posts < 3); i++) {
      await settle();
    }
    expect(posts, 3);
    expect(bodies.map((b) => b['session_id']).toSet().length, 1);
    expect(bodies.skip(1).every((b) => !b.containsKey('conversation_history')),
        true);
    expect(c.current!.messages.length, 6);
  });
  test('native admission holds two followers until durable completion',
      () async {
    var completed = false;
    final bodies = <Map<String, dynamic>>[];
    final c = await setup(FailingJournal(), (r) async {
      if (r.url.path.endsWith('capabilities')) {
        return http.Response(jsonEncode(capabilities), 200);
      }
      if (r.method == 'POST') {
        bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response(
            '{"run_id":"r${bodies.length}","status":"started"}', 202);
      }
      final id = r.url.path.split('/').last;
      return http.Response(
          jsonEncode({
            'run_id': id,
            'status': completed ? 'completed' : 'running',
            if (completed) 'output': 'actual'
          }),
          200);
    });
    addTearDown(c.dispose);
    expect(c.submit('first'), true);
    expect(c.submit('second'), true);
    expect(c.submit('third'), true);
    await settle();
    expect(bodies.length, 1);
    expect(c.outbox.map((e) => e.text), ['second', 'third']);
    completed = true;
    await c.checkRunStatus();
    await settle();
    expect(bodies.length, 3);
    expect(bodies.map((b) => b['session_id']).toSet().length, 1);
    expect(bodies.skip(1).every((b) => !b.containsKey('history')), true);
    expect(c.current!.messages.map((m) => m.content),
        ['first', 'actual', 'second', 'actual', 'third', 'actual']);
  });
}
