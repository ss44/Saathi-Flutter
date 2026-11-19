import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/remote_sessions.dart';

/// Alternate bounded real I/O and frames, stopping on observable completion.
Future<void> waitForHistoryState(
    WidgetTester tester, bool Function() ready, String description) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Timed out waiting for $description');
}

Future<void> revealRemoteHistory(WidgetTester tester,
    {required String sessionId,
    required Map<String, dynamic> connection,
    required String content}) async {
  final page = find.byType(RemoteHistoryPage);
  final list = find.descendant(of: page, matching: find.byType(ListView));
  // A lazy ListView can leave both its answer and spinner unbuilt. Waiting
  // for no animation (or only for request receipt) does not prove it loaded.
  await waitForHistoryState(tester, () {
    if (page.evaluate().length != 1 || list.evaluate().length != 1) {
      return false;
    }
    final route = ModalRoute.of(tester.element(page));
    if (route?.isCurrent != true ||
        route?.animation?.status != AnimationStatus.completed) {
      return false;
    }
    final owner = tester.widget<RemoteHistoryPage>(page);
    if (owner.session.id != sessionId ||
        !identical(owner.connection, connection)) {
      return false;
    }
    final children = (tester.widget<ListView>(list).childrenDelegate
            as SliverChildListDelegate)
        .children;
    return children.whereType<MessageView>().any((row) => row.text == content);
  }, 'loaded original session $sessionId and content: $content');
  final text = find.descendant(of: page, matching: find.text(content));
  final scroll =
      find.descendant(of: list, matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(text, 160,
      scrollable: scroll, maxScrolls: 40);
  await tester.pump();
  expect(text.hitTestable(), findsOneWidget);
  expect(tester.takeException(), isNull);
}
