import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/agent_runs/run_client.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
const _photoPart = {
  'type': 'image_url',
  'image_url': {'url': 'data:image/png;base64,$_png'},
};

ChatPhoto _photo() => ChatPhoto.fromBytes(base64Decode(_png));

class _HermesFixture {
  _HermesFixture({this.loseAck = false, this.official = true});

  final bool loseAck;
  final bool official;
  final posts = <http.Request>[];
  final historyRequests = <Uri>[];
  late final SaathiStore store;
  late final String chatId;

  Future<ChatController> start() async {
    SharedPreferences.setMockInitialValues({});
    store = SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySecrets(),
    );
    final controller = await restore();
    await controller.addConnection({
      'id': 'hermes',
      'name': 'Hermes API',
      'type': 'hermes',
      'url': 'https://hermes.example',
    }, 'fixture');
    await controller.newSession(
        controller.connections.single, 'hermes-agent', '');
    chatId = controller.current!.id;
    return controller;
  }

  Future<ChatController> restore() async {
    final controller = ChatController(
      store,
      coreFactory: () => SaathiCore(
          client: MockClient(
        (_) async => fail('Photo input must use the Hermes Runs adapter'),
      )),
      runClientFactory: (root, key) =>
          RunClient(root, key, client: MockClient(_handle)),
    );
    await controller.load();
    return controller;
  }

  Future<http.Response> _handle(http.Request request) async {
    switch (request.url.path) {
      case '/v1/capabilities':
        return http.Response(
            jsonEncode({
              if (official) 'object': 'hermes.api_server.capabilities',
              if (official) 'platform': 'hermes-agent',
              'features': {
                'run_submission': true,
                'run_status': true,
                'runs_idempotency': {'supported': true},
              },
              'endpoints': {
                'runs': {'method': 'POST', 'path': '/v1/runs'},
                'run_status': {'method': 'GET', 'path': '/v1/runs/{run_id}'},
              },
            }),
            200);
      case '/v1/runs':
        posts.add(request);
        final journal =
            jsonDecode((await store.secrets.read('run.v1.$chatId'))!);
        expect(journal['payload'], request.body);
        expect(journal['attempted'], isTrue);
        expect(request.headers['idempotency-key'], journal['key']);
        if (loseAck) throw http.ClientException('Lost receipt');
        return http.Response('{"run_id":"run_photo","status":"started"}', 202);
      case '/v1/runs/run_photo':
        return http.Response(
            '{"run_id":"run_photo","status":"completed","output":"I saw a red pixel."}',
            200);
      default:
        final body = jsonDecode(posts.single.body);
        final session = body['session_id'];
        expect(request.url.path, '/api/sessions/$session/messages');
        historyRequests.add(request.url);
        return http.Response(
            jsonEncode({
              'session_id': session,
              'data': [
                {'id': 1, ...body['input'].single as Map<String, dynamic>},
                {'id': 2, 'role': 'assistant', 'content': 'Recovered reply'},
              ],
            }),
            200);
    }
  }
}

Future<void> _openPhotos(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Add attachment'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Photo'));
  await tester.pumpAndSettle();
}

void _phone(WidgetTester tester, {double keyboard = 0}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 800);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets(
      'Hermes photos stay inside the draft until explicit image-only Send',
      (tester) async {
    _phone(tester, keyboard: 280);
    final fixture = _HermesFixture();
    final controller = await fixture.start();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: ChatHome(controller: controller, pickPhoto: () async => _photo()),
    ));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('composer'));
    await tester.enterText(
        input, 'A draft caption that is long enough to wrap.');
    await _openPhotos(tester);
    await _openPhotos(tester);

    final strip = find.byKey(const Key('draft-photos'));
    final thumbnails = find.descendant(of: strip, matching: find.byType(Image));
    expect(thumbnails, findsNWidgets(2));
    final outline = tester.getRect(find.byKey(const Key('composer-outline')));
    expect(tester.getTopLeft(strip).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(input).dy));
    expect(outline.contains(tester.getCenter(strip)), isTrue);
    expect(fixture.posts, isEmpty);

    await tester.tap(find.byTooltip('Remove photo 1'));
    await tester.enterText(input, '');
    await tester.pumpAndSettle();
    expect(thumbnails, findsOneWidget);
    await tester.tap(find.byTooltip('Send'));
    for (var frame = 0;
        frame < 120 &&
            (controller.busy || controller.current!.messages.isEmpty);
        frame++) {
      await tester.idle();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();

    expect(fixture.posts, hasLength(1), reason: controller.error);
    expect(jsonDecode(fixture.posts.single.body)['input'], [
      {
        'role': 'user',
        'content': [_photoPart]
      },
    ]);
    expect(strip, findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('I saw a red pixel.'), findsOneWidget);
    expect(controller.current!.messages.first.photos.single.base64Data, _png);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();

    final restored = await fixture.restore();
    addTearDown(restored.dispose);
    expect(restored.current!.messages.first.photos.single.base64Data, _png);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  test('lost Hermes receipt restores exact caption and photos without a resend',
      () async {
    final fixture = _HermesFixture(loseAck: true);
    final controller = await fixture.start();
    expect(await controller.verifyPhotoInput(), isTrue);
    final attempted = Completer<void>();
    controller.addListener(() {
      if (!controller.busy &&
          fixture.posts.isNotEmpty &&
          !attempted.isCompleted) {
        attempted.complete();
      }
    });
    expect(controller.submit('Caption', photos: [_photo()]), isTrue);
    await attempted.future.timeout(const Duration(seconds: 5));
    expect(controller.currentRun!.runId, isNull);
    expect(controller.current!.messages, isEmpty);
    controller.dispose();

    final restored = await fixture.restore();
    addTearDown(restored.dispose);
    final pending = restored.currentRun!;
    expect(pending.input, 'Caption');
    expect(pending.photos.single.base64Data, _png);
    expect(pending.payload, fixture.posts.single.body);
    expect(jsonDecode(pending.payload)['input'].single['content'], [
      {'type': 'text', 'text': 'Caption'},
      _photoPart,
    ]);
    await restored.checkRunStatus();
    expect(fixture.posts, hasLength(1));
    expect(fixture.historyRequests.single.queryParameters['inline_images'],
        'true');
    expect(restored.current!.messages.first.photos.single.base64Data, _png);
    expect(restored.current!.messages.last.content, 'Recovered reply');
  });

  testWidgets('a picker result is revoked even when selection returns',
      (tester) async {
    _phone(tester);
    final fixture = _HermesFixture();
    final controller = await fixture.start();
    final original = controller.current!;
    await controller.newSession(
        controller.connections.single, 'hermes-agent', '');
    final other = controller.current!;
    controller.select(original);
    final result = Completer<ChatPhoto?>();
    await tester.pumpWidget(MaterialApp(
      home: ChatHome(controller: controller, pickPhoto: () => result.future),
    ));
    await tester.pumpAndSettle();
    await _openPhotos(tester);
    controller.select(other);
    controller.select(original);
    result.complete(_photo());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('draft-photos')), findsNothing);
    expect(fixture.posts, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('an unverified API cannot open the picker or submit photos',
      (tester) async {
    _phone(tester);
    final fixture = _HermesFixture(official: false);
    final controller = await fixture.start();
    await tester.pumpWidget(MaterialApp(
      home: ChatHome(
        controller: controller,
        pickPhoto: () async => fail('The picker must stay unavailable'),
      ),
    ));
    await tester.pumpAndSettle();
    await _openPhotos(tester);
    expect(find.text('Could not verify photo support on this Hermes API.'),
        findsOneWidget);
    expect(controller.submit('Caption', photos: [_photo()]), isFalse);
    expect(fixture.posts, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
