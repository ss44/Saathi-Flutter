import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/chat_organization/reply_visibility.dart';
import 'package:saathi/chat_organization/organization.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('dialog above a reply is not read visibility; closing it is',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var seen = 0;
    late StateSetter update;
    var completed = false;
    final key = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return Scaffold(
          key: key,
          body: Column(children: [
            TextButton(
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        AlertDialog(title: const Text('Settings'), actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(key.currentContext!),
                              child: const Text('Close'))
                        ])),
                child: const Text('Open settings')),
            if (completed)
              ForegroundReplyVisibility(
                  replyIdentity: 'overlay-reply',
                  enabled: true,
                  onVisible: () async {
                    seen++;
                  },
                  child: const Text('New answer')),
          ]));
    })));
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    update(() => completed = true);
    await tester.pumpAndSettle();
    expect(seen, 0);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(seen, 1);
  });
  testWidgets(
      'hidden offstage answer is not visible even while route is foreground',
      (tester) async {
    var seen = 0;
    var hidden = true;
    late StateSetter update;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return Scaffold(
          body: Offstage(
              offstage: hidden,
              child: ForegroundReplyVisibility(
                  replyIdentity: 'hidden',
                  enabled: true,
                  onVisible: () async {
                    seen++;
                  },
                  child: const Text('Not painted'))));
    })));
    await tester.pumpAndSettle();
    expect(seen, 0);
    update(() => hidden = false);
    await tester.pumpAndSettle();
    expect(seen, 1);
  });
  testWidgets(
      'only foreground visible answer clears unseen, not drawer or offscreen selection',
      (tester) async {
    var seen = 0;
    SharedPreferences.setMockInitialValues({});
    final organization = ChatOrganization(
        OrganizationStorage(await SharedPreferences.getInstance()));
    await organization.load();
    const identity = ConversationIdentity('original', 'chat');
    await organization.recordCompletion(identity, 'reply');
    var drawerOpen = false;
    final scroll = ScrollController();
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
                  key: scaffold,
                  appBar: AppBar(title: const Text('Chat')),
                  onDrawerChanged: (open) => setState(() => drawerOpen = open),
                  drawer: const Drawer(child: Text('Conversations')),
                  body: ListView(controller: scroll, children: [
                    const SizedBox(height: 1800, child: Text('Older history')),
                    ForegroundReplyVisibility(
                        replyIdentity: 'reply',
                        enabled: !drawerOpen,
                        onVisible: () async {
                          if (organization.entry(identity).unread) seen++;
                          await organization.markReplyVisible(
                              identity, 'reply');
                        },
                        child: const Text('Actual completed answer')),
                  ]),
                ))));
    await tester.pump();
    expect(seen, 0);
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(seen, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    scaffold.currentState!.closeDrawer();
    await tester.pumpAndSettle();
    expect(seen, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(seen, 1);
    scroll.jumpTo(0);
    await tester.pump();
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(seen, 1);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });
}
