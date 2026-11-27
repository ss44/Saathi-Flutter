import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/remote_sessions.dart' as remote;
import 'package:saathi/core/saathi_core.dart' hide RemoteHistoryPage;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';
import 'package:saathi/agent_runs/run_client.dart';
import 'controller_http_test.dart' show makeStore;

void main() {
  testWidgets(
      'live empty response is explicit while historical empty rows disappear',
      (t) async {
    late ChatController c;
    await t.runAsync(() async {
      c = ChatController(await makeStore(),
          coreFactory: () => SaathiCore(
              client: MockClient((_) async => http.Response(
                  jsonEncode({
                    'choices': [
                      {
                        'message': {'content': ' \n'}
                      }
                    ]
                  }),
                  200))));
      await c.load();
      final connection = <String, dynamic>{
        'id': 'd',
        'name': 'Direct',
        'type': 'openai',
        'url': 'https://example.com'
      };
      await c.addConnection(connection, '');
      await c.newSession(connection, 'small', '');
      c.current!.messages.add(ChatMessage(role: 'model', content: ' '));
      await c.send('Question').timeout(const Duration(seconds: 5));
    });
    addTearDown(c.dispose);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    expect(c.error, contains('without a text response'));
    expect(find.textContaining('without a text response'), findsOneWidget);
    expect(c.current!.messages, hasLength(3));
    expect(find.byType(MessageView), findsOneWidget);
  });
  testWidgets(
      'bubbles retain author semantics and copy exact original markdown',
      (t) async {
    final semantics = t.ensureSemantics();
    String? copied;
    t.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    const original = 'Saathi: **actual name**\n\n```dart\nprint(1);\n```';
    await t.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Column(children: [
      MessageView(text: 'Question', user: true),
      MessageView(text: original, user: false)
    ]))));
    expect(find.bySemanticsLabel(RegExp('Assistant message')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Your message')), findsOneWidget);
    await t.longPress(find.byType(MessageView).last);
    await t.pumpAndSettle();
    expect(copied, original);
    expect(find.text('Copied'), findsOneWidget);
    semantics.dispose();
  });
  test(
      'continued server history retains structured visible content across reload',
      () async {
    final store = await makeStore();
    final client = MockClient((request) async => http.Response(
        jsonEncode(request.url.path == '/v1/capabilities'
            ? {
                'features': {
                  'run_submission': true,
                  'run_status': true,
                  'runs_idempotency': {'supported': true}
                },
                'endpoints': {
                  'runs': {'method': 'POST', 'path': '/v1/runs'},
                  'run_status': {'method': 'GET', 'path': '/v1/runs/{run_id}'}
                }
              }
            : {
                'session_id': 'remote',
                'data': [
                  {'role': 'user', 'content': 'Question'},
                  {'role': 'assistant', 'content': ' '},
                  {
                    'role': 'assistant',
                    'content': [
                      {
                        'type': 'image_url',
                        'image_url': {'url': 'https://untrusted.invalid/image'}
                      }
                    ]
                  },
                  {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': 'Saathi: answer'},
                      {'type': 'tool_use', 'input': 'PRIVATE'}
                    ]
                  },
                ],
                'pagination': {'has_more': false}
              }),
        200));
    final c = ChatController(store,
        coreFactory: () => SaathiCore(client: client),
        runClientFactory: (root, key) => RunClient(root, key, client: client));
    await c.load();
    final connection = <String, dynamic>{
      'id': 'h',
      'name': 'Hermes',
      'type': 'hermes',
      'url': 'https://example.com'
    };
    await c.addConnection(connection, '');
    await c.continueRemote(c.connections.single,
        RemoteSession({'id': 'remote', 'source': 'api_server'}));
    expect(c.current!.messages, hasLength(4));
    expect(c.current!.messages[2].content, contains('Image blocked'));
    expect(c.current!.messages.last.content, 'Saathi: answer');
    final restored = store.preferences.getString('saathi.chats.v1');
    expect(jsonEncode(restored), isNot(contains('PRIVATE')));
    expect(restored, isNotNull);
    expect(jsonEncode(restored), isNot(contains('untrusted.invalid')));
    c.dispose();
    final reloaded = ChatController(store);
    await reloaded.load();
    expect(reloaded.sessions.single.messages, hasLength(4));
    expect(reloaded.sessions.single.messages[2].content,
        contains('Image blocked'));
    expect(reloaded.sessions.single.messages.last.content, 'Saathi: answer');
    reloaded.dispose();
  });
  testWidgets('remote full empty page keeps pagination and content-only images',
      (t) async {
    final offsets = <int>[];
    final c = ChatController(await makeStore(),
        coreFactory: () => SaathiCore(client: MockClient((request) async {
              final offset = int.parse(request.url.queryParameters['offset']!);
              offsets.add(offset);
              return http.Response(
                  jsonEncode({
                    'session_id': 'remote',
                    'data': offset == 0
                        ? [
                            {'role': 'assistant', 'content': ' \n\t'},
                            {
                              'role': 'assistant',
                              'content': null,
                              'tool_calls': [
                                {'id': 'call-1'}
                              ]
                            },
                          ]
                        : [
                            {'role': 'tool', 'content': 'PRIVATE TOOL BODY'},
                            {
                              'role': 'assistant',
                              'content': [
                                {
                                  'type': 'image_url',
                                  'image_url': {
                                    'url': 'https://untrusted.invalid/image'
                                  }
                                }
                              ]
                            },
                            {
                              'role': 'assistant',
                              'content': [
                                {
                                  'type': 'text',
                                  'text': 'Saathi: visible answer'
                                },
                                {'type': 'tool_use', 'id': 'call-2'}
                              ]
                            },
                            {
                              'role': 'assistant',
                              'display_kind': 'hidden',
                              'content': 'HIDDEN'
                            },
                          ],
                    'pagination': {
                      'offset': offset,
                      'returned': offset == 0 ? 2 : 4,
                      'limit': 2,
                      if (offset != 0) 'has_more': false
                    }
                  }),
                  200);
            })));
    final connection = <String, dynamic>{
      'id': 'h',
      'name': 'Hermes',
      'type': 'hermes',
      'url': 'https://example.com'
    };
    c.connections.add(connection);
    addTearDown(c.dispose);
    await t.pumpWidget(MaterialApp(
        home: remote.RemoteHistoryPage(
            controller: c,
            connection: connection,
            session: RemoteSession({'id': 'remote', 'title': 'Remote'}))));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(find.byType(MessageView), findsNothing);
    expect(find.text('Load more history'), findsOneWidget);
    await t.tap(find.text('Load more history'));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(find.byType(MessageView), findsNWidgets(2));
    expect(find.textContaining('Image blocked'), findsOneWidget);
    expect(find.text('Saathi: visible answer'), findsOneWidget);
    expect(find.text('PRIVATE TOOL BODY'), findsNothing);
    expect(find.text('HIDDEN'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.text('Load more history'), findsNothing);
    expect(offsets, [0, 2]);
  });
  for (final width in [360.0, 390.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'left/right bubbles at $width 2x $brightness preserve content',
          (t) async {
        t.view.physicalSize = Size(width, 844);
        t.view.devicePixelRatio = 1;
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(t.view.reset);
        final theme = ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.teal, brightness: brightness));
        await t.pumpWidget(MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!),
            home: const Scaffold(
                body: SingleChildScrollView(
                    child: Padding(
                        padding: EdgeInsets.all(22),
                        child: Column(children: [
                          MessageView(text: 'Hi', user: true),
                          MessageView(
                              text:
                                  'Saathi: **answer**\n\n```dart\nprint(1);\n```',
                              user: false),
                        ]))))));
        await t.pumpAndSettle();
        expect(find.text('Saathi'), findsNothing);
        final views = find.byType(MessageView);
        AnimatedContainer bubble(int index) =>
            t.widget<AnimatedContainer>(find.descendant(
                of: views.at(index), matching: find.byType(AnimatedContainer)));
        final user = bubble(0);
        final assistant = bubble(1);
        expect((user.decoration as BoxDecoration).color,
            theme.colorScheme.secondaryContainer);
        expect((assistant.decoration as BoxDecoration).color,
            theme.colorScheme.surfaceContainerHighest);
        final userRect = t.getRect(find.byWidget(user));
        final assistantRect = t.getRect(find.byWidget(assistant));
        expect(userRect.right, closeTo(width - 22, .01));
        expect(userRect.width, lessThan((width - 44) * .85));
        expect(assistantRect.left, closeTo(22, .01));
        expect(assistantRect.right, lessThanOrEqualTo(width - 22));
        expect(find.textContaining('Saathi: '), findsOneWidget);
        await t.drag(views.last, const Offset(130, 0));
        await t.pumpAndSettle();
        expect(find.textContaining('Activity · Response received'),
            findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  }
  for (final (width, platform) in [
    (360.0, TargetPlatform.android),
    (760.0, TargetPlatform.linux),
    (1100.0, TargetPlatform.linux),
  ]) {
    testWidgets('long user bubbles respect the width cap at ${width}px',
        (t) async {
      t.view.physicalSize = Size(width, 844);
      t.view.devicePixelRatio = 1;
      if (platform == TargetPlatform.android) {
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
      }
      addTearDown(t.view.reset);
      const horizontalPadding = 22.0;
      await t.pumpWidget(MaterialApp(
        theme: ThemeData(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: MessageView(
              text: 'A long message that wraps across several lines.',
              user: true,
            ),
          ),
        ),
      ));
      final bubble = t.getRect(find.byType(AnimatedContainer));
      final availableWidth = width - 2 * horizontalPadding;
      final expectedWidth = (availableWidth * .85).clamp(0, 720);
      expect(bubble.width, closeTo(expectedWidth, .01));
      expect(bubble.right, closeTo(width - horizontalPadding, .01));
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
      'mixed history hides empty and tool rows without gaps or mutation',
      (t) async {
    final c = ChatController(await makeStore());
    await c.load();
    final connection = {
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'https://example.com'
    };
    await c.addConnection(connection, '');
    await c.newSession(connection, 'small', '');
    final rows = [
      ChatMessage(role: 'user', content: 'Question'),
      ChatMessage(role: 'assistant', content: '', id: 'blank'),
      ChatMessage(role: 'model', content: ' \n\t'),
      ChatMessage(role: 'tool', content: 'PRIVATE TOOL RESULT', id: 'tool'),
      ChatMessage(
          role: 'model',
          content: 'Tool activity: read_file',
          metadata: {'canonicalRowKind': 'toolActivity'}),
      ChatMessage(role: 'assistant', content: 'Saathi: actual **answer**'),
    ];
    c.current!.messages.addAll(rows);
    addTearDown(c.dispose);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await t.pumpAndSettle();
    expect(find.byType(MessageView), findsNWidgets(2));
    expect(find.text('PRIVATE TOOL RESULT'), findsNothing);
    expect(c.current!.messages, orderedEquals(rows));
    final first = find.byType(MessageView).first;
    final last = find.byType(MessageView).last;
    expect(t.getTopLeft(last).dy, closeTo(t.getBottomLeft(first).dy, .01));
    expect(find.textContaining('Tool activity: read_file'), findsNothing);
    await t.drag(last, const Offset(150, 0));
    await t.pumpAndSettle();
    expect(find.textContaining('Tool activity: read_file'), findsOneWidget);
  });
}
