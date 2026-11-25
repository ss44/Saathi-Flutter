import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime_flow_test.dart' show runtimeCapabilities;

class ParticipationSecrets extends MemorySecrets {
  bool failWrite = false;
  @override
  Future<void> write(String id, String value) async {
    if (failWrite) {
      failWrite = false;
      throw StateError('Controlled secret write failure');
    }
    await super.write(id, value);
  }
}

class ParticipationFixture {
  final secrets = ParticipationSecrets();
  late ChatController controller;
  final requests = <http.Request>[];
  final offsets = <int>[];
  bool deny = false, supported = true, failSecondPage = false;
  String source = 'api_server';
  Completer<void>? historyGate, discoveryGate;
  int pageCount = 1;
  Map<int, List<Map<String, dynamic>>>? historyPages;
  Future<void> start() async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((r) async {
      requests.add(r);
      Object body;
      if (r.url.path.endsWith('/capabilities')) {
        await discoveryGate?.future;
        body = supported ? runtimeCapabilities : <String, dynamic>{};
      } else if (r.url.path == '/api/sessions') {
        body = {
          'data': [
            {'id': 'external', 'source': source, 'title': 'External chat'}
          ],
          'has_more': false,
        };
      } else if (r.url.path.endsWith('/messages')) {
        final offset = int.parse(r.url.queryParameters['offset'] ?? '0');
        offsets.add(offset);
        await historyGate?.future;
        if (deny || (failSecondPage && offset == 2)) {
          return http.Response('{}', deny ? 403 : 503);
        }
        final rows = historyPages != null
            ? historyPages![offset] ?? <Map<String, dynamic>>[]
            : offset < pageCount * 2
                ? <Map<String, dynamic>>[
                    {'role': 'user', 'content': 'Context $offset'},
                    {'role': 'assistant', 'content': 'Reply $offset'}
                  ]
                : <Map<String, dynamic>>[];
        body = {
          'session_id': 'external',
          'data': rows,
          'pagination': {
            'offset': offset,
            'returned': rows.length,
            'limit': 2,
            'order': 'oldest',
          },
        };
      } else {
        throw StateError('Unexpected request: ${r.method} ${r.url.path}');
      }
      return http.Response(jsonEncode(body), 200);
    });
    controller = ChatController(
        SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: secrets),
        coreFactory: () => SaathiCore(client: client),
        runClientFactory: (root, key) => RunClient(root, key, client: client));
    await controller.load();
    await controller.addConnection({
      'id': 'h',
      'name': 'Original host',
      'type': 'hermes',
      'url': 'https://hermes.example',
    }, 'fixture');
  }

  Future<void> attach() => controller.continueRemote(
      controller.connections.single,
      RemoteSession({
        'id': 'external',
        'source': 'api_server',
        'title': 'External chat',
        'model': 'server-model',
        'provider': 'server-provider',
      }));
}

Future<void> network(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 30));
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
}

void main() {
  test('opening another server chat cannot bypass save-first recovery',
      () async {
    final f = ParticipationFixture();
    await f.start();
    addTearDown(f.controller.dispose);
    f.controller.unsavedChanges = true;
    await expectLater(f.attach(), throwsStateError);
    expect(f.requests, isEmpty);
    expect(f.controller.sessions, isEmpty);
    expect(f.controller.unsavedChanges, isTrue);
  });

  test(
      'opening another server chat cannot bypass save-first recovery during read',
      () async {
    final f = ParticipationFixture()..discoveryGate = Completer<void>();
    await f.start();
    addTearDown(f.controller.dispose);
    final opening = f.attach();
    await Future<void>.delayed(Duration.zero);
    expect(f.requests.any((r) => r.url.path.endsWith('/capabilities')), isTrue);
    f.controller.unsavedChanges = true;
    f.discoveryGate!.complete();
    await expectLater(opening, throwsStateError);
    expect(f.controller.sessions, isEmpty);
    expect(f.controller.unsavedChanges, isTrue);
  });

  test('hidden pages advance raw offsets and stable row IDs deduplicate',
      () async {
    final f = ParticipationFixture()
      ..historyPages = {
        0: [
          {'id': 1, 'role': 'tool', 'content': 'Private tool'},
          {
            'id': 2,
            'role': 'assistant',
            'display_kind': 'hidden',
            'content': 'Private hidden'
          },
        ],
        2: [
          {'id': 3, 'role': 'user', 'content': 'Original input'},
          {'id': 4, 'role': 'assistant', 'content': 'Original reply'},
        ],
        4: [
          {'id': 4, 'role': 'assistant', 'content': 'Original reply'},
          {'id': 5, 'role': 'user', 'content': 'Original input'},
        ],
      };
    await f.start();
    addTearDown(f.controller.dispose);
    await f.attach();
    expect(f.offsets, [0, 2, 4, 6]);
    expect(f.controller.current!.messages.map((m) => m.content),
        ['Original input', 'Original reply', 'Original input']);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
  });

  test('failed credential mutation cannot revive an in-flight attachment',
      () async {
    final f = ParticipationFixture()..historyGate = Completer<void>();
    await f.start();
    addTearDown(f.controller.dispose);
    final pending = f.attach();
    final rejected = expectLater(pending, throwsStateError);
    for (var i = 0; i < 100 && f.offsets.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(f.offsets, [0]);
    final original = f.controller.connections.single;
    f.secrets.failWrite = true;
    await expectLater(
        f.controller.updateConnection('h', original, apiKey: 'replacement'),
        throwsStateError);
    expect(identical(f.controller.connections.single, original), isTrue);
    f.secrets.failWrite = false;
    f.historyGate!.complete();
    await rejected;
    expect(f.controller.sessions, isEmpty);
    expect(f.controller.current, isNull);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
  });

  test('attachment keeps all oldest-first pages and retries without sending',
      () async {
    final f = ParticipationFixture()
      ..pageCount = 2
      ..failSecondPage = true;
    await f.start();
    addTearDown(f.controller.dispose);
    await expectLater(f.attach(), throwsA(isA<ProviderException>()));
    expect(f.controller.current, isNull);
    expect(f.controller.sessions, isEmpty);
    f.failSecondPage = false;
    await f.attach();
    expect(f.controller.current!.messages.map((m) => m.content),
        ['Context 0', 'Reply 0', 'Context 2', 'Reply 2']);
    expect(f.offsets, [0, 2, 0, 2, 4]);
    expect(f.controller.current!.connectionId, 'h');
    expect(f.controller.current!.remoteSessionId, 'external');
    expect(f.controller.current!.model, 'server-model');
    expect(f.controller.current!.upstreamProvider, 'server-provider');
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
  });

  testWidgets('unsupported Runs explains upgrade and retry without replay',
      (t) async {
    final f = ParticipationFixture()..supported = false;
    await f.start();
    addTearDown(f.controller.dispose);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: f.controller)));
    await t.tap(find.byTooltip('Open navigation menu'));
    await network(t);
    await t.tap(find.text('External chat'));
    await network(t);
    expect(f.controller.current, isNull);
    expect(find.textContaining('does not advertise'), findsOneWidget);
    expect(find.text('Context 0'), findsOneWidget);
    f.supported = true;
    await t.tap(find.text('Try connecting again'));
    await network(t);
    await t.pumpAndSettle();
    expect(f.controller.current?.remoteSessionId, 'external');
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('denied history retries into the same ready conversation',
      (t) async {
    final f = ParticipationFixture()..deny = true;
    await f.start();
    addTearDown(f.controller.dispose);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: f.controller)));
    await t.tap(find.byTooltip('Open navigation menu'));
    await network(t);
    await t.tap(find.text('External chat'));
    await network(t);
    expect(f.controller.current, isNull);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('permission'), findsOneWidget);
    f.deny = false;
    await t.tap(find.text('Try again'));
    await network(t);
    await t.pumpAndSettle();
    expect(f.controller.current?.remoteSessionId, 'external');
    expect(find.byKey(const Key('composer')).hitTestable(), findsOneWidget);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
    await t.pumpWidget(const SizedBox());
  });

  for (final boundary in ['lifecycle', 'failed key save', 'rotation', 'back']) {
    testWidgets('opening revokes stale history on $boundary', (t) async {
      final f = ParticipationFixture();
      await f.start();
      addTearDown(f.controller.dispose);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(MaterialApp(home: ChatHome(controller: f.controller)));
      await t.tap(find.byTooltip('Open navigation menu'));
      await network(t);
      f.historyGate = Completer<void>();
      await t.tap(find.text('External chat'));
      await network(t);
      expect(f.offsets, [0]);
      if (boundary == 'lifecycle') {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          t.binding.handleAppLifecycleStateChanged(state);
          await t.pump();
        }
      } else if (boundary == 'back') {
        // Allow the drawer close animation to finish before tapping Cancel.
        await t.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const Key('cancel-remote-open')).hitTestable(),
          findsOneWidget,
        );
        await t.tap(find.byKey(const Key('cancel-remote-open')));
        await t.pumpAndSettle();
      } else {
        f.secrets.failWrite = boundary == 'failed key save';
        final changed = f.controller.updateConnection(
            'h', f.controller.connections.single,
            apiKey: 'replacement');
        if (boundary == 'failed key save') {
          await expectLater(changed, throwsStateError);
        } else {
          await changed;
        }
      }
      final before = f.requests.length;
      f.historyGate!.complete();
      await network(t);
      expect(f.controller.current, isNull);
      expect(f.controller.sessions, isEmpty);
      expect(f.requests.length, before, reason: 'No stale follow-on discovery');
      expect(find.text('Context 0'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'drawer keeps current view visible while native discovery is pending',
      (t) async {
    final f = ParticipationFixture();
    await f.start();
    addTearDown(f.controller.dispose);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: f.controller)));
    await t.tap(find.byTooltip('Open navigation menu'));
    await network(t);
    f.discoveryGate = Completer<void>();
    await t.tap(find.text('External chat'));
    await network(t);
    expect(find.byKey(const Key('remote-connecting-banner')), findsOneWidget);
    expect(find.text('Continue conversation'), findsNothing);
    expect(f.controller.current, isNull);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
    f.discoveryGate!.complete();
    await network(t);
    expect(f.controller.current!.remoteSessionId, 'external');
    expect(
        t.widget<TextField>(find.byKey(const Key('composer'))).enabled, isTrue);
    await t.pumpWidget(const SizedBox());
  });
}
