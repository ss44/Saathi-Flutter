import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/core/saathi_core.dart' show ChatMessage;
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/remote_sessions.dart';
import 'package:saathi/ui/transcript_latest.dart';

import 'review38_history_refresh_test.dart' show RefreshFixture;
import 'ui/remote_participation_test.dart' show network;

void main() {
  for (final change in ['edited', 'shorter', 'divergent extension']) {
    testWidgets('drawer explains $change and retry preserves original reader',
        (t) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = RefreshFixture();
      await t.runAsync(() async {
        await f.start();
        f.rows = List.generate(
            30,
            (i) => {
                  'id': i,
                  'role': i.isEven ? 'user' : 'assistant',
                  'content': 'Original row $i ${'retained history ' * 12}',
                });
        await f.open();
      });
      addTearDown(f.close);
      final original = f.c.current!;
      final connection = f.c.connections.single;
      final answer = original.messages[1];
      original.messages[1] = ChatMessage(
          role: answer.role,
          content: answer.content,
          id: 'existing-completion',
          metadata: {'authoritativeCompletion': true});
      final before = [...original.messages];
      final authoritative = [...f.rows];
      final generation = f.c.selectionGeneration;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  viewInsets: const EdgeInsets.only(bottom: 180)),
              child: child!),
          home: ChatHome(controller: f.c)));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('composer')), 'Private draft');
      final list = find.descendant(
          of: find.byType(TranscriptLatest), matching: find.byType(ListView));
      final reader =
          find.descendant(of: list, matching: find.byType(Scrollable));
      final position = t.state<ScrollableState>(reader).position;
      position.jumpTo(position.maxScrollExtent / 2);
      await t.pumpAndSettle();
      await t.drag(list, const Offset(0, 100));
      await t.pumpAndSettle();
      final offset = position.pixels;
      expect(offset, greaterThan(0));
      expect(position.extentAfter, greaterThan(position.viewportDimension));
      if (change == 'shorter') {
        f.rows = authoritative.take(29).toList();
      } else {
        f.rows = [...authoritative];
        f.rows[1] = {...f.rows[1], 'content': 'Externally corrected answer'};
        if (change == 'divergent extension') f.extend();
      }
      await t.tap(find.byTooltip('Settings'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.byTooltip('Browse remote sessions'), 150,
          scrollable: find.byType(Scrollable).last);
      await t.tap(find.byTooltip('Browse remote sessions'));
      await network(t);
      final sessionsScroll = find
          .descendant(
              of: find.byType(RemoteSessionsPage),
              matching: find.byType(Scrollable))
          .first;
      final row = find.descendant(
          of: find.byType(RemoteSessionsPage),
          matching: find.text('External chat'));
      await t.scrollUntilVisible(row, 150, scrollable: sessionsScroll);
      await t.tap(row);
      await network(t);
      await t.pumpAndSettle();
      expect(find.byType(RemoteHistoryPage), findsOneWidget);
      final warning = find.textContaining('cannot be safely combined');
      final scroll = find.descendant(
          of: find.byType(RemoteHistoryPage),
          matching: find.byType(Scrollable));
      await t.scrollUntilVisible(find.text('Try connecting again'), 150,
          scrollable: scroll);
      expect(warning, findsOneWidget);
      expect(find.text('Try connecting again').hitTestable(), findsOneWidget);
      expect(f.c.current, same(original));
      expect(original.messages, before);
      for (var i = 0; i < before.length; i++) {
        expect(original.messages[i], same(before[i]));
      }
      expect(f.c.connections.single, same(connection));
      expect(original.model, 'original-model');
      expect(original.upstreamProvider, 'original-provider');
      expect(original.connectionId, 'original');
      expect(original.remoteSessionId, 'external');
      expect(f.c.selectionGeneration, generation);
      expect(f.reads, 3);
      // Retry does not resolve edits destructively. The original host must once
      // again provide an exact prefix; only its newly appended row is imported.
      f.rows = [...authoritative];
      f.extend();
      await t.tap(find.text('Try connecting again'));
      await network(t);
      await t.pumpAndSettle();
      expect(find.byType(RemoteHistoryPage), findsNothing);
      expect(f.c.current, same(original));
      expect(f.c.sessions, [original]);
      expect(original.messages.take(before.length), before);
      expect(original.messages.last.content, 'External new third row');
      expect(original.messages[1], same(before[1]));
      expect(original.messages[1].id, 'existing-completion');
      expect(
          original.messages.last.metadata['authoritativeCompletion'], isNull);
      expect(f.c.organization.entry(f.c.identityOf(original)).unread, isFalse);
      expect(f.replies, isEmpty);
      expect(f.c.readOnly, isFalse);
      expect(f.c.error, isNull);
      expect(f.reads, 4);
      expect(f.requests.every((r) => r.method == 'GET'), isTrue);
      expect(
          t
              .widget<TextField>(find.byKey(const Key('composer')))
              .controller!
              .text,
          'Private draft');
      expect(t.state<ScrollableState>(reader).position, same(position));
      expect(position.pixels, closeTo(offset, 1));
      await t.pumpWidget(const SizedBox());
    });
  }
}
