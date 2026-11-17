import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/canonical_controls.dart';
import 'hermes_gateway_test.dart' show Fixture, snapshot;

void main() {
  testWidgets(
      'native busy choices preserve next-turn FIFO and pending Stop at 360px 2x',
      (tester) async {
    HttpOverrides.global =
        null; // Test-only: real localhost upgrade, not Flutter HTTP mock.
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = Fixture();
    late CanonicalChat chat;
    await tester.runAsync(() async {
      await fixture.start();
      fixture.respond = (r) => switch (r['method']) {
            'session.resume' => snapshot(),
            'prompt.submit' => {
                'admission_id': 'run',
                'ref': {'session_id': 'chat', 'profile_id': 'profile'},
                'authority_epoch': 3,
                'execution_generation': 4,
                'status': 'started'
              },
            _ => {
                'authority_epoch': 3,
                'execution_generation': 4,
                'status': 'queued'
              },
          };
      chat = CanonicalChat(
          HermesGatewayClient(grantProvider: () async => fixture.grant()),
          MemorySecrets(),
          source: 'source',
          isCurrent: () => true);
      await chat.connect();
      await chat.attach('chat');
      await chat.send('work');
    });
    final composer = TextEditingController(text: 'A long draft ' * 30);
    final queued = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(
                textScaler: TextScaler.linear(2),
                viewInsets: EdgeInsets.only(bottom: 280)),
            child: Scaffold(
                body: CanonicalComposerControls(
                    chat: chat,
                    composer: composer,
                    queue: (text) {
                      queued.add(text);
                      return true;
                    })))));
    await tester.tap(find.byTooltip('Use draft while Hermes works'));
    await tester.pumpAndSettle();
    expect(find.text('Guide current work'), findsOneWidget);
    expect(find.text('Correct current work'), findsOneWidget);
    await tester.tap(find.text('Guide current work'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(composer.text, isEmpty);
    expect(queued, isEmpty);
    expect(chat.pending, isTrue);
    composer.text = 'Next after interrupt';
    await tester.pump();
    await tester.tap(find.byTooltip('Use draft while Hermes works'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Interrupt, then queue draft'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(queued, ['Next after interrupt']);
    expect(chat.pending, isTrue);
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      fixture.respond = (r) => r['method'] == 'session.resume'
          ? {
              ...snapshot(),
              'prompts': [
                {
                  'kind': 'approval',
                  'prompt_id': 'review',
                  'execution_generation': 4,
                  'choices': ['once', 'deny'],
                  'description': 'A long request to review ' * 20
                },
              ]
            }
          : {'status': 'resolved', 'prompt_id': 'review'};
      await chat.attach('chat');
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review action'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('once'));
    await tester.tap(find.text('once'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(fixture.requests.where((r) => r['method'] == 'approval.respond'),
        hasLength(1));
    expect(fixture.requests.where((r) => r['method'] == 'prompt.submit'),
        hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    composer.dispose();
    await tester.runAsync(() async {
      await chat.close();
      await fixture.close();
    });
  });
}
