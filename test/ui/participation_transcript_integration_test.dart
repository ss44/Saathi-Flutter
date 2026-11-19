import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/transcript_presentation.dart';

import 'remote_participation_test.dart' show ParticipationFixture, network;

void main() {
  testWidgets(
      'drawer participation preserves paged blocked images and filtering',
      (t) async {
    final f = ParticipationFixture()
      ..historyPages = {
        0: [
          {'id': 1, 'role': 'tool', 'content': 'Private tool body'},
          {
            'id': 2,
            'role': 'assistant',
            'display_kind': 'hidden',
            'content': 'Private hidden body',
          },
        ],
        2: [
          {'id': 3, 'role': 'assistant', 'content': ' \n '},
          {
            'id': 4,
            'role': 'assistant',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'https://untrusted.example/image.png'},
              },
            ],
          },
        ],
        4: [
          {'id': 5, 'role': 'user', 'content': 'Last original input'},
          {'id': 6, 'role': 'assistant', 'content': 'Last original answer'},
        ],
      };
    await f.start();
    addTearDown(f.controller.dispose);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: ChatHome(controller: f.controller)));
    await t.tap(find.byTooltip('Open navigation menu'));
    await network(t);
    await t.tap(find.text('External chat'));
    for (var i = 0; i < 30 && f.controller.current == null; i++) {
      await network(t);
    }
    await t.pumpAndSettle();
    final session = f.controller.current!;
    expect(session.connectionId, 'h');
    expect(session.remoteSessionId, 'external');
    expect(f.controller.sessions, hasLength(1));
    expect(f.controller.readOnly, isFalse);
    expect(find.text('Continue conversation'), findsNothing);
    expect(find.byKey(const Key('composer')).hitTestable(), findsOneWidget);
    expect(f.offsets, containsAllInOrder([0, 2, 4, 6]));
    // Keep the raw blank record, but never mount a blank/tool answer bubble.
    expect(session.messages, hasLength(4));
    expect(session.messages.first.content.trim(), isEmpty);
    expect(session.messages.where(showsHistoryBubble).map((m) => m.content), [
      'Image blocked · attachment preview is unavailable',
      'Last original input',
      'Last original answer',
    ]);
    expect(find.text('Image blocked · attachment preview is unavailable'),
        findsOneWidget);
    expect(find.text('Private tool body'), findsNothing);
    expect(find.text('Private hidden body'), findsNothing);
    expect(
        t
            .widgetList<MessageView>(find.byType(MessageView))
            .every((w) => w.text.trim().isNotEmpty),
        isTrue);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
    expect(f.requests.every((r) => r.url.host == 'hermes.example'), isTrue);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await network(t);
  });
}
