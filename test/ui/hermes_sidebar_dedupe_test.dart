import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/chat_organization/organization_widgets.dart';
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/canonical_connection.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/connections.dart';
import 'package:saathi/ui/conversation_servers.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime_flow_test.dart' show runtimeCapabilities;
import 'remote_participation_test.dart' show network;

class _RouteRecorder extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

Future<ChatController> _makeController({
  required http.Client client,
  List<Map<String, dynamic>> connections = const [],
  List<ChatSession> sessions = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = SaathiStore(
    preferences: await SharedPreferences.getInstance(),
    secrets: MemorySecrets(),
  );
  final controller = ChatController(
    store,
    coreFactory: () => SaathiCore(client: client),
    runClientFactory: (root, key) => RunClient(root, key, client: client),
  );
  await controller.load();
  for (final conn in connections) {
    await controller.addConnection(conn, 'fixture-key');
  }
  for (final session in sessions) {
    controller.sessions.add(session);
  }
  if (sessions.isNotEmpty) {
    controller.select(sessions.first);
  }
  return controller;
}

void main() {
  group('Hermes sidebar deduplication', () {
    testWidgets(
      'hides already-continued local API sessions from ConversationServer while preserving uncontinued API and read-only ordering and connection isolation',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final client = MockClient((r) async {
          if (r.url.path == '/v1/capabilities') {
            return http.Response(jsonEncode(runtimeCapabilities), 200);
          }
          if (r.url.path == '/api/sessions') {
            final isPrimary = r.url.host == 'primary.example';
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'shared-id',
                    'title': isPrimary
                        ? 'Continued Primary Chat'
                        : 'Secondary Same ID Chat',
                    'source': 'api_server',
                    'last_message_at': '2026-11-22T12:00:00Z',
                  },
                  if (isPrimary) ...[
                    {
                      'id': 'cli-1',
                      'title': 'CLI Read-Only Chat',
                      'source': 'cli',
                      'last_message_at': '2026-11-22T18:00:00Z',
                    },
                    {
                      'id': 'api-uncontinued',
                      'title': 'Uncontinued API Chat',
                      'source': 'api_server',
                      'last_message_at': '2026-11-22T10:00:00Z',
                    },
                  ],
                ],
                'has_more': false,
              }),
              200,
            );
          }
          throw StateError('Unexpected ${r.method} ${r.url}');
        });

        final continuedLocal = ChatSession(
          id: 'local-continued',
          connectionId: 'hermes-primary',
          remoteSessionId: 'shared-id',
          remoteTitle: 'Continued Primary Chat',
          model: 'hermes-model',
          messages: [
            ChatMessage(
              role: 'user',
              content: 'Continued Primary Chat',
              metadata: const {'timestamp': '2026-11-22T12:00:00Z'},
            ),
          ],
        );

        final controller = await _makeController(
          client: client,
          connections: const [
            {
              'id': 'hermes-primary',
              'name': 'Primary Hermes',
              'type': 'hermes',
              'url': 'https://primary.example',
            },
            {
              'id': 'hermes-secondary',
              'name': 'Secondary Hermes',
              'type': 'hermes',
              'url': 'https://secondary.example',
            },
          ],
          sessions: [continuedLocal],
        );
        addTearDown(() {
          controller.dispose();
          client.close();
        });

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester
            .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
        await network(tester);
        await tester.pumpAndSettle();

        final servers = find.byType(ConversationServer);
        expect(servers, findsNWidgets(2));
        final primaryServer = servers.first;
        final secondaryServer = servers.last;

        // Continued primary API chat appears ONCE (under On this device), not duplicated under Primary Hermes.
        expect(
          find.descendant(
            of: find.byType(ConversationActionRow),
            matching: find.text('Continued Primary Chat'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: primaryServer,
            matching: find.text('Continued Primary Chat'),
          ),
          findsNothing,
        );

        // Secondary Hermes with the same remoteSessionId is NOT hidden (different connectionId).
        expect(
          find.descendant(
            of: secondaryServer,
            matching: find.text('Secondary Same ID Chat'),
          ),
          findsOneWidget,
        );

        // Uncontinued interactive API chat stays above read-only CLI chat (#90).
        final primaryTiles = tester
            .widgetList<ListTile>(
              find.descendant(
                  of: primaryServer, matching: find.byType(ListTile)),
            )
            .toList();
        // Index 0 is the server header ('Primary Hermes'), then sessions.
        expect((primaryTiles[1].title! as Text).data, 'Uncontinued API Chat');
        expect(primaryTiles[1].tileColor, isNull);
        expect((primaryTiles[2].title! as Text).data, 'CLI Read-Only Chat');
        expect(
          primaryTiles[2].tileColor,
          readOnlyConversationTileColor(tester.element(primaryServer)),
        );
        expect(
          find.descendant(
            of: find.widgetWithText(ListTile, 'CLI Read-Only Chat'),
            matching: find.text('Read-only'),
          ),
          findsOneWidget,
        );

        // Deleting the local continued chat restores it under Primary Hermes automatically.
        await controller.clear();
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: primaryServer,
            matching: find.text('Continued Primary Chat'),
          ),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'shows clear non-empty status when all loaded server chats are already on this device',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final client = MockClient((r) async {
          if (r.url.path == '/v1/capabilities') {
            return http.Response(jsonEncode(runtimeCapabilities), 200);
          }
          if (r.url.path == '/api/sessions') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'only-api',
                    'title': 'Only Server Chat',
                    'source': 'api_server',
                  },
                ],
                'has_more': false,
              }),
              200,
            );
          }
          throw StateError('Unexpected ${r.method} ${r.url}');
        });

        final controller = await _makeController(
          client: client,
          connections: const [
            {
              'id': 'hermes-only',
              'name': 'Solo Hermes',
              'type': 'hermes',
              'url': 'https://solo.example',
            },
          ],
          sessions: [
            ChatSession(
              id: 'local-only',
              connectionId: 'hermes-only',
              remoteSessionId: 'only-api',
              remoteTitle: 'Only Server Chat',
              model: 'hermes-model',
            ),
          ],
        );
        addTearDown(() {
          controller.dispose();
          client.close();
        });

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester
            .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
        await network(tester);
        await tester.pumpAndSettle();

        final server = find.byType(ConversationServer);
        expect(
          find.descendant(of: server, matching: find.text('Only Server Chat')),
          findsNothing,
        );
        expect(
          find.descendant(of: server, matching: find.text('No conversations')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: server,
            matching: find.text('All loaded chats are on this device'),
          ),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('Smooth opening of continuable API sessions', () {
    testWidgets(
      'attaches interactive API session inline without pushing a transient RemoteHistoryPage and retains visible history while connecting',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final requests = <http.Request>[];
        Completer<void>? historyGate;
        final client = MockClient((r) async {
          requests.add(r);
          if (r.url.path == '/v1/capabilities') {
            return http.Response(jsonEncode(runtimeCapabilities), 200);
          }
          if (r.url.path == '/api/sessions') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'api-smooth',
                    'title': 'Smooth API Chat',
                    'source': 'api_server',
                    'model': 'hermes-pro',
                  },
                  {
                    'id': 'desktop-ro',
                    'title': 'Desktop Read-Only Chat',
                    'source': 'desktop',
                  },
                ],
                'has_more': false,
              }),
              200,
            );
          }
          if (r.url.path == '/api/sessions/api-smooth/messages') {
            await historyGate?.future;
            return http.Response(
              jsonEncode({
                'session_id': 'api-smooth',
                'data': [
                  {'id': 1, 'role': 'user', 'content': 'Remote prompt'},
                  {'id': 2, 'role': 'assistant', 'content': 'Remote answer'},
                ],
                'pagination': {
                  'offset': 0,
                  'limit': 100,
                  'returned': 2,
                  'has_more': false,
                  'order': 'oldest',
                },
              }),
              200,
            );
          }
          if (r.url.path == '/api/sessions/desktop-ro/messages') {
            return http.Response(
              jsonEncode({
                'session_id': 'desktop-ro',
                'data': [
                  {
                    'id': 1,
                    'role': 'assistant',
                    'content': 'Desktop only answer'
                  },
                ],
                'pagination': {'has_more': false},
              }),
              200,
            );
          }
          throw StateError('Unexpected ${r.method} ${r.url}');
        });

        final existingLocal = ChatSession(
          id: 'local-active',
          connectionId: 'hermes-1',
          model: 'hermes-pro',
          messages: [
            ChatMessage(role: 'user', content: 'Current visible question'),
            ChatMessage(role: 'model', content: 'Current visible answer'),
          ],
        );

        final controller = await _makeController(
          client: client,
          connections: const [
            {
              'id': 'hermes-1',
              'name': 'My Hermes',
              'type': 'hermes',
              'url': 'https://hermes.example',
            },
          ],
          sessions: [existingLocal],
        );
        addTearDown(() {
          controller.dispose();
          client.close();
        });

        final recorder = _RouteRecorder();
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [recorder],
            home: ChatHome(controller: controller),
          ),
        );
        await network(tester);
        await tester.pumpAndSettle();

        final initialPushCount = recorder.pushed.length;
        historyGate = Completer<void>();

        await tester.tap(find.text('Smooth API Chat'));
        await network(tester);

        // No transient RemoteHistoryPage route pushed; existing visible chat stays on screen.
        expect(find.byType(RemoteHistoryPage), findsNothing);
        expect(recorder.pushed.length, initialPushCount);
        expect(find.text('Current visible answer'), findsOneWidget);
        expect(
            find.byKey(const Key('remote-connecting-banner')), findsOneWidget);

        historyGate.complete();
        await network(tester);
        await tester.pumpAndSettle();

        expect(find.byType(RemoteHistoryPage), findsNothing);
        expect(recorder.pushed.length, initialPushCount);
        expect(controller.current?.remoteSessionId, 'api-smooth');
        expect(find.text('Remote answer'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byKey(const Key('composer'))).enabled,
          isTrue,
        );
        // After continuation, Smooth API Chat is deduplicated out of ConversationServer.
        expect(
          find.descendant(
            of: find.byType(ConversationServer),
            matching: find.text('Smooth API Chat'),
          ),
          findsNothing,
        );
        // Only GET requests were issued (no replay/inference).
        expect(requests.every((r) => r.method == 'GET'), isTrue);

        // Tapping a read-only desktop session still opens RemoteHistoryPage honestly.
        await tester.tap(find.text('Desktop Read-Only Chat'));
        await network(tester);
        await tester.pumpAndSettle();

        expect(find.byType(RemoteHistoryPage), findsOneWidget);
        expect(find.text('Gateway connection required'), findsOneWidget);
        expect(find.text('Desktop only answer'), findsOneWidget);
        expect(requests.every((r) => r.method == 'GET'), isTrue);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('ConnectionsPage and CanonicalConnectionPage improvements', () {
    testWidgets(
      'ConnectionsPage exposes Hermes Desktop / CLI entry alongside Add connection and uses CanonicalConnectionRoute',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final controller = ChatController(
          SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets(),
          ),
        );
        addTearDown(controller.dispose);
        await controller.load();

        await tester.pumpWidget(
          MaterialApp(home: ConnectionsPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        final gatewayButton = find.byKey(const Key('connect-hermes-gateway'));
        expect(gatewayButton, findsOneWidget);
        expect(find.text('Connect Hermes Desktop / CLI'), findsOneWidget);
        expect(
          find.textContaining('Hermes Desktop / CLI'),
          findsAtLeastNWidgets(1),
        );

        // Disabled when connections cannot be changed.
        controller.busy = true;
        controller.notifyListeners();
        await tester.pumpAndSettle();
        expect(
          tester.widget<OutlinedButton>(gatewayButton).onPressed,
          isNull,
        );

        controller.busy = false;
        controller.notifyListeners();
        await tester.pumpAndSettle();

        await tester.tap(gatewayButton);
        await tester.pumpAndSettle();

        expect(find.byType(CanonicalConnectionPage), findsOneWidget);
        expect(
          ModalRoute.of(tester.element(find.byType(CanonicalConnectionPage))),
          isA<CanonicalConnectionRoute<void>>(),
        );

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'CanonicalConnectionPage provides concise steps and paste affordances while preserving security invariants at 360px/2x',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(tester.view.reset);

        String clipboardText = '';
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{'text': clipboardText};
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });

        SharedPreferences.setMockInitialValues({});
        final controller = ChatController(
          SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: MemorySecrets(),
          ),
        );
        addTearDown(controller.dispose);
        await controller.load();

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
              ),
              child: child!,
            ),
            home: CanonicalConnectionPage(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        final listScroll = find
            .descendant(
              of: find.byType(CanonicalConnectionPage),
              matching: find.byType(Scrollable),
            )
            .first;

        // Concise steps are reachable and no layout overflow at 360px/2x + keyboard.
        await tester.scrollUntilVisible(
          find.textContaining('hermes gateway attach --json'),
          150,
          scrollable: listScroll,
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('hermes gateway attach --json'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        // URL starts empty (no default trust).
        await tester.scrollUntilVisible(
          find.byKey(const Key('gateway-trusted-url')),
          150,
          scrollable: listScroll,
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('gateway-trusted-url')))
              .controller!
              .text,
          isEmpty,
        );

        // Paste invite JSON into obscured invite field: NEVER auto-populates trusted URL.
        const secretTicket = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
        clipboardText = jsonEncode({
          'state': 'ready',
          'url': 'wss://attacker.example/api/ws',
          'protocol': 'hermes-gateway-v1',
          'ticket': secretTicket,
          'protocols': [
            'hermes-gateway-v1',
            'hermes-gateway-ticket.$secretTicket',
          ],
          'endpoint': {'profile_id': 'p1', 'instance_id': 'i1'},
        });

        await tester.scrollUntilVisible(
          find.byKey(const Key('paste-gateway-invite')),
          150,
          scrollable: listScroll,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('paste-gateway-invite')));
        await tester.pumpAndSettle();

        final inviteField = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Host-issued invite JSON'),
        );
        expect(inviteField.obscureText, isTrue);
        expect(inviteField.controller!.text, clipboardText);

        // Trusted URL must STILL be empty (never rewritten from invite JSON).
        await tester.scrollUntilVisible(
          find.byKey(const Key('gateway-trusted-url')),
          -150,
          scrollable: listScroll,
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('gateway-trusted-url')))
              .controller!
              .text,
          isEmpty,
        );

        // Paste a trusted WSS address via the URL paste affordance.
        clipboardText = 'wss://trusted.example/api/ws';
        await tester.tap(find.byKey(const Key('paste-gateway-url')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('gateway-trusted-url')))
              .controller!
              .text,
          'wss://trusted.example/api/ws',
        );

        // Connecting with mismatched invite URL fails closed without leaking the ticket.
        await tester.scrollUntilVisible(
          find.text('Trust this host and connect'),
          150,
          scrollable: listScroll,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Trust this host and connect'));
        await tester.pumpAndSettle();

        expect(find.textContaining('Could not connect.'), findsOneWidget);
        expect(find.textContaining(secretTicket), findsNothing);
        await tester.scrollUntilVisible(
          find.widgetWithText(TextField, 'Host-issued invite JSON'),
          -150,
          scrollable: listScroll,
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(
                find.widgetWithText(TextField, 'Host-issued invite JSON'),
              )
              .controller!
              .text,
          isEmpty,
        );
        expect(tester.takeException(), isNull);

        // When reconnecting an existing targetSession, trusted URL stays read-only with no URL paste button.
        final target = ChatSession(
          id: 'canonical-1',
          connectionId: 'gw-1',
          remoteSessionId: 'native-chat',
          canonicalProfileId: 'profile-1',
          model: 'Hermes Desktop / CLI',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: CanonicalConnectionPage(
              key: const ValueKey('reconnect-target'),
              controller: controller,
              connection: const {
                'id': 'gw-1',
                'name': 'Bound Host',
                'type': 'hermesGateway',
                'url': 'wss://bound.example/api/ws',
              },
              targetSession: target,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final reconnectScroll = find
            .descendant(
              of: find.byType(CanonicalConnectionPage),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('gateway-trusted-url')),
          150,
          scrollable: reconnectScroll,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('paste-gateway-url')), findsNothing);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('gateway-trusted-url')))
              .readOnly,
          isTrue,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('paste-gateway-invite')),
          150,
          scrollable: reconnectScroll,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('paste-gateway-invite')), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
