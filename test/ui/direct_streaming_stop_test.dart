import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _FailingStore extends SaathiStore {
  _FailingStore(SharedPreferences preferences)
      : super(preferences: preferences, secrets: MemorySecrets());
  bool failSaveChats = false;

  @override
  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    if (failSaveChats) throw StateError('disk full');
    await super.saveChats(chats);
  }
}

Future<SaathiStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  return SaathiStore(
    preferences: await SharedPreferences.getInstance(),
    secrets: MemorySecrets(),
  );
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition timed out',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  int maxSteps = 200,
  String reason = 'widget condition timed out',
}) async {
  for (var i = 0; i < maxSteps && !predicate(); i++) {
    await tester.idle();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(predicate(), isTrue, reason: reason);
}

void main() {
  for (final provider in ['openai', 'anthropic', 'gemini']) {
    testWidgets('$provider streams SSE chunks progressively and commits once',
        (tester) async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      late HttpServer server;
      late ChatController controller;
      final clients = <http.Client>[];
      final allowSecondChunk = Completer<void>();
      final firstChunkFlushed = Completer<void>();
      var requestCount = 0;
      String? seenPath;
      String? seenQuery;
      Map<String, dynamic>? seenBody;

      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requestCount++;
          seenPath = request.uri.path;
          seenQuery = request.uri.query;
          seenBody = jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
          request.response.headers.contentType =
              ContentType('text', 'event-stream');
          request.response.bufferOutput = false;
          switch (provider) {
            case 'openai':
              request.response.write(
                'data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n',
              );
            case 'anthropic':
              request.response.write(
                'event: message_start\n'
                'data: {"type":"message_start","message":{"usage":{"input_tokens":11}}}\n\n'
                'event: content_block_delta\n'
                'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hidden"}}\n\n'
                'event: content_block_delta\n'
                'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello "}}\n\n',
              );
            case 'gemini':
              request.response.write(
                'data: {"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"Hello "}]}}]}\n\n',
              );
          }
          await request.response.flush();
          if (!firstChunkFlushed.isCompleted) firstChunkFlushed.complete();
          await allowSecondChunk.future;
          switch (provider) {
            case 'openai':
              request.response.write(
                'data: {"choices":[{"delta":{"content":"world!"},"finish_reason":"stop"}]}\n\n'
                'data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4,"total_tokens":15}}\n\n'
                'data: [DONE]\n\n',
              );
            case 'anthropic':
              request.response.write(
                'event: content_block_delta\n'
                'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"world!"}}\n\n'
                'event: message_delta\n'
                'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}\n\n'
                'event: message_stop\n'
                'data: {"type":"message_stop"}\n\n',
              );
            case 'gemini':
              request.response.write(
                'data: {"candidates":[{"content":{"parts":[{"text":"world!"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":11,"candidatesTokenCount":4,"totalTokenCount":15}}\n\n',
              );
          }
          await request.response.flush();
          await request.response.close();
        });

        controller = ChatController(
          await _makeStore(),
          coreFactory: () {
            final httpClient = _RealHttpOverrides().createHttpClient(null)
              ..idleTimeout = Duration.zero;
            final ioClient = IOClient(httpClient);
            clients.add(ioClient);
            return SaathiCore(client: ioClient);
          },
        );
        await controller.load();
        final conn = {
          'id': 'p-$provider',
          'name': provider,
          'type': provider,
          'url': 'http://127.0.0.1:${server.port}',
        };
        await controller.addConnection(conn, 'fixture-key');
        await controller.newSession(conn, 'test-model', 'Be helpful');
      });

      try {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester
            .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
        await tester.enterText(find.byKey(const Key('composer')), 'Greet me');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();

        await _pumpUntil(
          tester,
          () =>
              firstChunkFlushed.isCompleted &&
              controller.streamingText == 'Hello ',
          reason: 'first streamed chunk for $provider did not arrive',
        );
        await tester.pump();

        expect(controller.busy, isTrue);
        expect(controller.canStopDirectReply, isTrue);
        expect(controller.streamingText, 'Hello ');
        expect(find.textContaining('Hello'), findsOneWidget);
        expect(find.textContaining('hidden'), findsNothing);
        expect(find.byTooltip('Stop reply'), findsOneWidget);
        expect(controller.current!.messages, isEmpty);

        allowSecondChunk.complete();
        await _pumpUntil(
          tester,
          () => !controller.busy && controller.current!.messages.length == 2,
          reason: 'final commit for $provider did not complete',
        );
        await tester.pumpAndSettle();

        expect(requestCount, 1);
        expect(controller.streamingText, isNull);
        expect(controller.canStopDirectReply, isFalse);
        expect(find.byTooltip('Stop reply'), findsNothing);
        expect(controller.current!.messages.map((m) => m.content), [
          'Greet me',
          'Hello world!',
        ]);
        final reply = controller.current!.messages.last;
        expect(reply.metadata['authoritativeCompletion'], isTrue);
        expect(reply.metadata['promptTokens'], 11);
        expect(reply.metadata['completionTokens'], 4);
        if (provider == 'openai') {
          expect(seenPath, '/v1/chat/completions');
          expect(seenBody?['stream'], isTrue);
        } else if (provider == 'anthropic') {
          expect(seenPath, '/v1/messages');
          expect(seenBody?['stream'], isTrue);
        } else {
          expect(seenPath, '/v1beta/models/test-model:streamGenerateContent');
          expect(seenQuery, 'alt=sse');
        }
      } finally {
        if (!allowSecondChunk.isCompleted) allowSecondChunk.complete();
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        for (final client in clients) {
          client.close();
        }
        await tester.runAsync(() => server.close(force: true));
      }
    });
  }

  test(
      'non-SSE plain JSON responses work cleanly for openai, anthropic, gemini',
      () async {
    for (final provider in ['openai', 'anthropic', 'gemini']) {
      final client = MockClient((request) async {
        return switch (provider) {
          'openai' => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'Plain OpenAI'}
                  }
                ],
                'usage': {'prompt_tokens': 2, 'completion_tokens': 3}
              }),
              200,
            ),
          'anthropic' => http.Response(
              jsonEncode({
                'content': [
                  {'type': 'thinking', 'thinking': 'secret'},
                  {'type': 'text', 'text': 'Plain Anthropic'}
                ],
                'usage': {'input_tokens': 2, 'output_tokens': 3}
              }),
              200,
            ),
          _ => http.Response(
              jsonEncode([
                {
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {'text': 'Plain '}
                        ]
                      }
                    }
                  ]
                },
                {
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {'text': 'Gemini'}
                        ]
                      },
                      'finishReason': 'STOP'
                    }
                  ],
                  'usageMetadata': {
                    'promptTokenCount': 2,
                    'candidatesTokenCount': 3,
                    'totalTokenCount': 5
                  }
                }
              ]),
              200,
              headers: {'content-type': 'application/json'},
            ),
        };
      });
      final c = ChatController(
        await _makeStore(),
        coreFactory: () => SaathiCore(client: client),
      );
      await c.load();
      final conn = {
        'id': 'plain-$provider',
        'name': provider,
        'type': provider,
        'url': 'https://example.com',
      };
      await c.addConnection(conn, 'key');
      await c.newSession(conn, 'model', '');
      expect(await c.send('Ping'), isTrue);
      expect(
        c.current!.messages.last.content,
        switch (provider) {
          'openai' => 'Plain OpenAI',
          'anthropic' => 'Plain Anthropic',
          _ => 'Plain Gemini',
        },
      );
      expect(c.current!.messages.last.metadata['promptTokens'], 2);
      expect(c.current!.messages.last.metadata['completionTokens'], 3);
      expect(c.streamingText, isNull);
      c.dispose();
    }
  });

  testWidgets(
      'Stop mid-stream aborts transport, keeps partial truthfully, never marks authoritative completion, and pauses queued followers',
      (tester) async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    late HttpServer server;
    late ChatController controller;
    final clients = <http.Client>[];
    var posts = 0;
    var replyNotifications = 0;
    final holdFirst = Completer<void>();
    final firstChunkSent = Completer<void>();

    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        posts++;
        final body = await utf8.decoder.bind(request).join();
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        request.response.bufferOutput = false;
        if (posts == 1) {
          request.response.write(
            'data: {"choices":[{"delta":{"content":"Partial answer"}}]}\n\n',
          );
          await request.response.flush();
          if (!firstChunkSent.isCompleted) firstChunkSent.complete();
          try {
            await holdFirst.future.timeout(const Duration(seconds: 5));
          } catch (_) {}
          try {
            await request.response.close();
          } catch (_) {}
          return;
        }
        expect(body, contains('Queued follower'));
        request.response.write(
          'data: {"choices":[{"delta":{"content":"Follower answer"},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
        );
        await request.response.flush();
        await request.response.close();
      });

      controller = ChatController(
        await _makeStore(),
        coreFactory: () {
          final httpClient = _RealHttpOverrides().createHttpClient(null)
            ..idleTimeout = Duration.zero;
          final ioClient = IOClient(httpClient);
          clients.add(ioClient);
          return SaathiCore(
            client: ioClient,
            requestTimeout: const Duration(seconds: 30),
          );
        },
      );
      controller.onReplyReceived = (_) => replyNotifications++;
      await controller.load();
      final conn = {
        'id': 'stop-conn',
        'name': 'Local',
        'type': 'openai',
        'url': 'http://127.0.0.1:${server.port}',
      };
      await controller.addConnection(conn, '');
      await controller.newSession(conn, 'model', '');
    });

    try {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester
          .pumpWidget(MaterialApp(home: ChatHome(controller: controller)));

      await tester.enterText(find.byKey(const Key('composer')), 'First prompt');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      await _pumpUntil(
        tester,
        () =>
            firstChunkSent.isCompleted &&
            controller.streamingText == 'Partial answer',
        reason: 'first partial chunk did not arrive',
      );
      await tester.pump();

      // Queue a follow-up while the first reply is streaming.
      await tester.enterText(
          find.byKey(const Key('composer')), 'Queued follower');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(controller.outbox.map((item) => item.text), ['Queued follower']);

      // Tap Stop reply.
      await tester.tap(find.byTooltip('Stop reply'));
      await _pumpUntil(
        tester,
        () => !controller.busy,
        reason: 'Stop did not abort the request promptly',
      );
      await tester.pumpAndSettle();

      expect(posts, 1,
          reason: 'Stopped request must not resend or auto-drain follower');
      expect(replyNotifications, 0,
          reason: 'Stopped partial reply must never fire completion alert');
      expect(controller.streamingText, isNull);
      expect(controller.canStopDirectReply, isFalse);
      expect(controller.uncertainInput, isNull);
      expect(controller.current!.messages.map((m) => m.content), [
        'First prompt',
        'Partial answer',
      ]);
      final partial = controller.current!.messages.last;
      expect(partial.metadata['stoppedByUser'], isTrue);
      expect(partial.metadata['incomplete'], isTrue);
      expect(partial.metadata['authoritativeCompletion'], isNot(true));
      expect(
        controller.organization
            .entry(controller.identityOf(controller.current!))
            .unread,
        isFalse,
      );
      expect(
        controller.queueStatus,
        'Stopped work pauses the queue. Review the result before choosing Resume.',
      );
      expect(controller.outbox.map((item) => item.text), ['Queued follower']);
      expect(controller.canResumeQueue, isTrue);
      expect(find.text('Resume queue'), findsOneWidget);

      // User reviews and explicitly chooses Resume queue.
      await tester.tap(find.text('Resume queue'));
      await _pumpUntil(
        tester,
        () => !controller.busy && controller.current!.messages.length == 4,
        reason: 'Resumed follower did not complete',
      );
      await tester.pumpAndSettle();

      expect(posts, 2);
      expect(replyNotifications, 1);
      expect(controller.current!.messages.last.content, 'Follower answer');
      expect(
          controller.current!.messages.last.metadata['authoritativeCompletion'],
          isTrue);
      expect(controller.outbox, isEmpty);
    } finally {
      if (!holdFirst.isCompleted) holdFirst.complete();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      for (final client in clients) {
        client.close();
      }
      await tester.runAsync(() => server.close(force: true));
    }
  });

  test(
      'Stop before any text arrives avoids fake bubble and discards prepared input cleanly',
      () async {
    final requestStarted = Completer<void>();
    final neverReply = Completer<http.Response>();
    var posts = 0;
    final store = await _makeStore();
    final c = ChatController(
      store,
      coreFactory: () => SaathiCore(
        client: MockClient((_) {
          posts++;
          if (!requestStarted.isCompleted) requestStarted.complete();
          return neverReply.future;
        }),
      ),
    );
    addTearDown(c.dispose);
    await c.load();
    final conn = {
      'id': 'a',
      'name': 'A',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(conn, '');
    await c.newSession(conn, 'small', '');

    expect(c.submit('Will stop early'), isTrue);
    await requestStarted.future;
    await _waitFor(() => c.canStopDirectReply);
    expect(c.submit('Follower after early stop'), isTrue);

    expect(c.stopDirectReply(), isTrue);
    await _waitFor(() => !c.busy);

    expect(posts, 1);
    expect(c.current!.messages, isEmpty);
    expect(c.streamingText, isNull);
    expect(c.uncertainInput, isNull);
    expect(c.error, contains('stopped before any text arrived'));
    expect(
      c.queueStatus,
      'Stopped work pauses the queue. Review the result before choosing Resume.',
    );
    expect(c.outbox.map((e) => e.text), ['Follower after early stop']);
    expect(c.canResumeQueue, isTrue);
    final persistedPrepared =
        store.preferences.getString(ChatController.preparedInputsKey);
    expect(persistedPrepared == null || persistedPrepared == '[]', isTrue);
  });

  test(
      'mid-stream truncation, SSE error, timeout, and save failure preserve uncertain-outcome and no-resend invariants',
      () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    for (final mode in ['truncated', 'sse_error', 'timeout']) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var posts = 0;
      server.listen((request) async {
        posts++;
        await request.drain<void>();
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        request.response.bufferOutput = false;
        request.response.write(
          'data: {"choices":[{"delta":{"content":"Partial before $mode"}}]}\n\n',
        );
        await request.response.flush();
        if (mode == 'sse_error') {
          request.response.write(
            'event: error\ndata: {"error":{"message":"upstream failed"}}\n\n',
          );
          await request.response.close();
        } else if (mode == 'timeout') {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          try {
            await request.response.close();
          } catch (_) {}
        } else {
          await request.response.close();
        }
      });

      final c = ChatController(
        await _makeStore(),
        coreFactory: () => SaathiCore(
          client: IOClient(_RealHttpOverrides().createHttpClient(null)),
          requestTimeout: mode == 'timeout'
              ? const Duration(milliseconds: 60)
              : const Duration(seconds: 5),
        ),
      );
      try {
        await c.load();
        final conn = {
          'id': 'm-$mode',
          'name': mode,
          'type': 'openai',
          'url': 'http://127.0.0.1:${server.port}',
        };
        await c.addConnection(conn, '');
        await c.newSession(conn, 'model', '');
        expect(await c.send('Hello $mode'), isFalse);
        expect(posts, 1);
        expect(c.current!.messages, isEmpty);
        expect(c.streamingText, isNull);
        expect(c.uncertainInput?.text, 'Hello $mode');
        expect(c.queueStatus, contains('Outcome unknown'));
        expect(c.canResumeQueue, isFalse);
      } finally {
        c.dispose();
        await server.close(force: true);
      }
    }

    // Storage save failure after Stop with partial text keeps unsavedChanges and pauses queue.
    SharedPreferences.setMockInitialValues({});
    final failingStore = _FailingStore(await SharedPreferences.getInstance());
    final streamCtrl = StreamController<List<int>>();
    final chunkSent = Completer<void>();
    final c = ChatController(
      failingStore,
      coreFactory: () => SaathiCore(
        client: MockClient.streaming((request, _) async {
          scheduleMicrotask(() {
            streamCtrl.add(utf8.encode(
              'data: {"choices":[{"delta":{"content":"Unsaved partial"}}]}\n\n',
            ));
            chunkSent.complete();
          });
          return http.StreamedResponse(
            streamCtrl.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      ),
    );
    await c.load();
    final conn = {
      'id': 'save-fail',
      'name': 'Fail',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(conn, '');
    await c.newSession(conn, 'model', '');
    failingStore.failSaveChats = true;

    expect(c.submit('Trigger save failure'), isTrue);
    await chunkSent.future;
    await _waitFor(() => c.streamingText == 'Unsaved partial');
    expect(c.stopDirectReply(), isTrue);
    await _waitFor(() => !c.busy);

    expect(c.unsavedChanges, isTrue);
    expect(c.current!.messages.last.content, 'Unsaved partial');
    expect(c.current!.messages.last.metadata['authoritativeCompletion'],
        isNot(true));
    expect(c.error, contains('could not be saved'));
    await streamCtrl.close();
    c.dispose();
  });

  test('bounded streaming preview caps memory and cleans up on dispose',
      () async {
    final streamCtrl = StreamController<List<int>>();
    final c = ChatController(
      await _makeStore(),
      coreFactory: () => SaathiCore(
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            streamCtrl.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      ),
    );
    await c.load();
    final conn = {
      'id': 'bound',
      'name': 'Bound',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(conn, '');
    await c.newSession(conn, 'model', '');

    expect(c.submit('Huge stream'), isTrue);
    await _waitFor(() => c.canStopDirectReply);

    final bigChunk = 'x' * (100 * 1024);
    for (var i = 0; i < 4; i++) {
      streamCtrl.add(utf8.encode(
        'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': bigChunk}
                }
              ]
            })}\n\n',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await _waitFor(() => (c.streamingText?.length ?? 0) > 0);
    expect(
      c.streamingText!.length,
      ChatController.maxStreamPreviewLength,
    );

    // Disposing mid-stream aborts cleanly without throwing.
    c.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.streamingText, isNull);
    await streamCtrl.close();
  });

  testWidgets(
      'direct streaming preserves older-history scroll offset and follows live edge when at bottom',
      (tester) async {
    final streamCtrl = StreamController<List<int>>();
    final c = ChatController(
      await _makeStore(),
      coreFactory: () => SaathiCore(
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            streamCtrl.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      ),
    );
    await c.load();
    final conn = {
      'id': 'scroll',
      'name': 'Scroll',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(conn, '');
    await c.newSession(conn, 'model', '');
    c.current!.messages.addAll(
      List.generate(
        50,
        (i) => ChatMessage(
          role: 'model',
          content: 'History row $i with enough text to overflow the viewport.',
        ),
      ),
    );

    try {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
      await tester.pumpAndSettle();

      // Start at the live bottom edge of the long conversation.
      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('composer')), 'Stream please');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await _pumpUntil(tester, () => c.canStopDirectReply);

      streamCtrl.add(utf8.encode(
        'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'Start of stream'}
                }
              ]
            })}\n\n',
      ));
      await _pumpUntil(tester, () => c.streamingText == 'Start of stream');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      final list = find.byType(ListView).first;
      final scroller = tester.widget<ListView>(list).controller!;
      expect(scroller.position.extentAfter, lessThan(120));

      // Scroll up into older history.
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(0, -900),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();
      final offsetWhileReadingHistory = scroller.offset;
      expect(scroller.position.extentAfter, greaterThan(400));

      // Emit lots of streaming output; reader must NOT be yanked to the bottom.
      final growth = List.filled(25, '\n\nMore streamed paragraphs.').join();
      streamCtrl.add(utf8.encode(
        'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': growth}
                }
              ]
            })}\n\n',
      ));
      await _pumpUntil(
        tester,
        () => c.streamingText!.contains('More streamed paragraphs.'),
      );
      await tester.pump();
      expect(scroller.offset, closeTo(offsetWhileReadingHistory, 2));
      expect(find.byTooltip('Jump to latest'), findsOneWidget);

      // Tapping Jump to latest returns to live edge and follows subsequent chunks.
      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pumpAndSettle();
      expect(scroller.position.extentAfter, lessThan(2));

      final tail = List.filled(15, '\n\nFollowing live edge again.').join();
      streamCtrl.add(utf8.encode(
        'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': tail}
                }
              ]
            })}\n\n',
      ));
      await _pumpUntil(
        tester,
        () => c.streamingText!.contains('Following live edge again.'),
      );
      await tester.pump();
      expect(scroller.position.extentAfter, lessThan(120));

      streamCtrl.add(utf8.encode('data: [DONE]\n\n'));
      await streamCtrl.close();
      await _pumpUntil(tester, () => !c.busy);
      await tester.pumpAndSettle();
    } finally {
      if (!streamCtrl.isClosed) unawaited(streamCtrl.close());
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });

  testWidgets(
      '360px 2x text with keyboard keeps Stop reply usable and allows New conversation without leaking stream',
      (tester) async {
    tester.view.physicalSize = const Size(360, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final streamCtrl = StreamController<List<int>>();
    final c = ChatController(
      await _makeStore(),
      coreFactory: () => SaathiCore(
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            streamCtrl.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      ),
    );
    await c.load();
    final conn = {
      'id': 'small-screen',
      'name': 'Compact',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(conn, '');
    await c.newSession(conn, 'model-a', '');
    final firstSession = c.current!;

    try {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 280),
            ),
            child: child!,
          ),
          home: ChatHome(controller: c),
        ),
      );

      // When idle, Send is present and Stop reply is absent.
      expect(find.byTooltip('Send'), findsOneWidget);
      expect(find.byTooltip('Stop reply'), findsNothing);

      await tester.enterText(find.byKey(const Key('composer')), 'Compact test');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await _pumpUntil(tester, () => c.canStopDirectReply);

      streamCtrl.add(utf8.encode(
        'data: {"choices":[{"delta":{"content":"Streaming on small screen"}}]}\n\n',
      ));
      await _pumpUntil(
        tester,
        () => c.streamingText == 'Streaming on small screen',
      );
      await tester.pump();

      final stopFinder = find.byTooltip('Stop reply');
      expect(stopFinder.hitTestable(), findsOneWidget);
      expect(find.byTooltip('Send'), findsOneWidget);
      final stopRect = tester.getRect(stopFinder);
      expect(stopRect.width, greaterThanOrEqualTo(48));
      expect(stopRect.height, greaterThanOrEqualTo(48));
      expect(stopRect.bottom, lessThanOrEqualTo(844 - 280));
      expect(stopRect.left, greaterThanOrEqualTo(0));
      expect(stopRect.right, lessThanOrEqualTo(360));

      // New conversation is enabled during direct streaming and does not leak stream.
      final newChatBtn = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.add_rounded),
          matching: find.byType(IconButton),
        ),
      );
      expect(newChatBtn.onPressed, isNotNull);

      await tester.runAsync(() => c.newSession(conn, 'model-b', ''));
      await tester.pump();
      expect(c.current, isNot(same(firstSession)));
      expect(c.streamingText, isNull);
      expect(c.canStopDirectReply, isFalse);
      expect(find.byTooltip('Stop reply'), findsNothing);
      expect(find.text('Streaming on small screen'), findsNothing);

      // Switch back to the original conversation and stop it cleanly.
      c.select(firstSession);
      await tester.pump();
      expect(c.streamingText, 'Streaming on small screen');
      expect(c.canStopDirectReply, isTrue);
      await tester.tap(find.byTooltip('Stop reply'));
      await _pumpUntil(tester, () => !c.busy);
      await tester.pumpAndSettle();

      expect(firstSession.messages.last.content, 'Streaming on small screen');
      expect(tester.takeException(), isNull);
    } finally {
      if (!streamCtrl.isClosed) unawaited(streamCtrl.close());
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });

  test(
      'stoppedByUser and incomplete metadata survive store.load() restart and send()->stopDirectReply() prunes _paused',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
    final firstStream = StreamController<List<int>>();
    var callCount = 0;
    final c = ChatController(
      store,
      coreFactory: () => SaathiCore(
        client: MockClient.streaming((request, _) async {
          callCount++;
          if (callCount == 1) {
            return http.StreamedResponse(
              firstStream.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(
                '{"choices":[{"message":{"content":"Second reply"}}]}')),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );
    await c.load();
    final conn = {
      'id': 'restart-stop',
      'name': 'Direct',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(conn, '');
    await c.newSession(conn, 'm1', '');

    // Invoke send() directly (outside _drainOutbox) with an empty outbox.
    final sendFuture = c.send('First prompt');
    while (!c.canStopDirectReply) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    firstStream.add(utf8.encode(
        'data: {"choices":[{"delta":{"content":"Partial answer"}}]}\n\n'));
    while (c.streamingText != 'Partial answer') {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    c.stopDirectReply();
    await sendFuture;
    unawaited(firstStream.close());

    // Stopped metadata survives cold reload via SaathiStore.load().
    final reloaded = ChatController(
      SaathiStore(preferences: prefs, secrets: MemorySecrets()),
    );
    await reloaded.load();
    final restoredAssistant = reloaded.sessions.single.messages.last;
    expect(restoredAssistant.content, 'Partial answer');
    expect(restoredAssistant.metadata['stoppedByUser'], isTrue);
    expect(restoredAssistant.metadata['incomplete'], isTrue);
    expect(restoredAssistant.metadata['authoritativeCompletion'], isNull);
    reloaded.dispose();

    // Subsequent send() works cleanly because orphaned _paused was pruned.
    expect(await c.send('Follow-up prompt'), isTrue);
    expect(c.current!.messages.last.content, 'Second reply');
    c.dispose();
  });

  test(
      'stopping with queued follower preserves storage-failure pause notices instead of clobbering them',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FailingStore(prefs);
    final streamCtrl = StreamController<List<int>>();
    final c = ChatController(
      store,
      coreFactory: () => SaathiCore(
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            streamCtrl.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      ),
    );
    await c.load();
    final conn = {
      'id': 'fail-stop',
      'name': 'Direct',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(conn, '');
    await c.newSession(conn, 'm1', '');

    expect(c.submit('First'), isTrue);
    while (!c.canStopDirectReply) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(c.submit('Follower'), isTrue);
    streamCtrl.add(utf8.encode(
        'data: {"choices":[{"delta":{"content":"Unsaved part"}}]}\n\n'));
    while (c.streamingText != 'Unsaved part') {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    store.failSaveChats = true;
    c.stopDirectReply();
    while (c.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    unawaited(streamCtrl.close());

    expect(c.unsavedChanges, isTrue);
    expect(c.queueStatus,
        'Queue paused until the response is saved. Then choose Resume.');
    c.dispose();
  });

  test(
      'overlapping newSession() during stream completion serializes persist() without losing committed replies',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
    final streamCtrl = StreamController<List<int>>();
    final c = ChatController(
      store,
      coreFactory: () => SaathiCore(
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            streamCtrl.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      ),
    );
    await c.load();
    final conn = {
      'id': 'concurrent',
      'name': 'Direct',
      'type': 'openai',
      'url': 'https://example.com',
    };
    await c.addConnection(conn, '');
    await c.newSession(conn, 'm1', '');
    final sessionA = c.current!;

    expect(c.submit('Hello A'), isTrue);
    while (!c.canStopDirectReply) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    streamCtrl.add(utf8.encode(
        'data: {"choices":[{"delta":{"content":"Answer A"}}]}\n\ndata: [DONE]\n\n'));
    // Fire newSession concurrently with stream completion.
    final newSessionFuture = c.newSession(conn, 'm2', '');
    await streamCtrl.close();
    await newSessionFuture;
    while (c.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final reloaded = ChatController(
      SaathiStore(preferences: prefs, secrets: MemorySecrets()),
    );
    await reloaded.load();
    expect(reloaded.sessions, hasLength(2));
    final persistedA =
        reloaded.sessions.singleWhere((s) => s.id == sessionA.id);
    expect(persistedA.messages.last.content, 'Answer A');
    reloaded.dispose();
    c.dispose();
  });

  test(
      'Gemini ignores FINISH_REASON_UNSPECIFIED and OpenAI skips empty keepalive frames and rejects non-Map JSON',
      () async {
    final geminiCore = SaathiCore(
      client: MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(
            'data: {"candidates":[{"content":{"parts":[{"text":"Half"}]},"finishReason":"FINISH_REASON_UNSPECIFIED"}]}\n\n',
          )),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    geminiCore.addProvider(const ProviderConfig(
      id: 'g',
      name: 'Gemini',
      type: ProviderType.gemini,
      baseUrl: 'https://example.com',
      apiKey: 'k',
    ));
    const geminiModel = ModelInfo(providerId: 'g', name: 'gemini-pro');
    geminiCore.registerModel(geminiModel);
    geminiCore.selectModel(geminiModel.id);
    await expectLater(
      geminiCore.streamMessage('hi').toList(),
      throwsA(isA<ProviderException>()),
    );
    geminiCore.close();

    final openaiCore = SaathiCore(
      client: MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(
            'data: \n\n'
            'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n'
            'data: [DONE]\n\n',
          )),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    openaiCore.addProvider(const ProviderConfig(
      id: 'o',
      name: 'OpenAI',
      type: ProviderType.openai,
      baseUrl: 'https://example.com',
      apiKey: 'k',
    ));
    const openaiModel = ModelInfo(providerId: 'o', name: 'gpt-4o');
    openaiCore.registerModel(openaiModel);
    openaiCore.selectModel(openaiModel.id);
    final chunks = await openaiCore.streamMessage('hi').toList();
    expect(chunks.map((c) => c.text).join(), 'OK');
    openaiCore.close();

    final badJsonCore = SaathiCore(
      client: MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: null\n\ndata: [DONE]\n\n')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    badJsonCore.addProvider(const ProviderConfig(
      id: 'o2',
      name: 'OpenAI',
      type: ProviderType.openai,
      baseUrl: 'https://example.com',
      apiKey: 'k',
    ));
    const badJsonModel = ModelInfo(providerId: 'o2', name: 'gpt-4o');
    badJsonCore.registerModel(badJsonModel);
    badJsonCore.selectModel(badJsonModel.id);
    await expectLater(
      badJsonCore.streamMessage('hi').toList(),
      throwsA(isA<ProviderException>()),
    );
    badJsonCore.close();
  });
}
