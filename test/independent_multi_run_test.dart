import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/agent_activity/activity_owner.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'runtime_flow_test.dart' show RuntimeFixture;
import 'runtime_recovery_test.dart' show connect, until;

void main() {
  testWidgets(
      'two native sources with equal run ids isolate terminals and show Resume for A',
      (t) async {
    HttpOverrides.global = null;
    final a = RuntimeFixture();
    final b = RuntimeFixture();
    late ChatController c;
    late ActivityOwner owner;
    await t.runAsync(() async {
      await a.start();
      await b.start();
      c = await connect(a);
      owner = ActivityOwner(c);
    });
    try {
      await t.runAsync(() async {
        await c.send('A input');
        final chatA = c.current!;
        await until(() => c.streamingText != null);
        expect(c.submit('A follower held by pending run'), isTrue);
        await c.addConnection({
          'id': 'b',
          'name': 'B',
          'type': 'hermes',
          'url': 'http://127.0.0.1:${b.server.port}'
        }, 'b-fixture');
        await c.continueRemote(c.connections.last,
            RemoteSession({'id': 'external_chat', 'source': 'api_server'}));
        await c.send('B input');
        final chatB = c.current!;
        await until(() => c.streamingText != null);
        expect(c.runs[chatA.id]!.runId, c.runs[chatB.id]!.runId);
        a.terminalOutput = 'A final';
        a.completed = true;
        a.emit('run.completed', {});
        await until(() => c.runs[chatA.id]!.committed);
        expect(c.runs[chatB.id]!.committed, isFalse);
        expect(chatA.messages.last.content, 'A final');
        expect(chatB.messages.length, 2);
        expect(c.runPending, isTrue);
        b.terminalOutput = 'B final';
        b.completed = true;
        b.emit('run.completed', {});
        await until(() => c.runs[chatB.id]!.committed);
        expect(chatB.messages.last.content, 'B final');
        expect(a.submissions, 1);
        expect(b.submissions, 1);
        c.select(chatA);
        expect(c.outbox, hasLength(1));
        expect(c.queueStatus, isNotNull,
            reason:
                'Remote continuation must pause accepted followers when switching away');
        expect(c.canResumeQueue, isTrue);
      });
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
      await t.pump();
      expect(find.text('Resume queue'), findsOneWidget);
      expect(find.text('A follower held by pending run'), findsOneWidget);
      expect(a.submissions, 1);
      expect(b.submissions, 1);
    } finally {
      await t.pumpWidget(const SizedBox());
      owner.dispose();
      c.dispose();
      await t.runAsync(() async {
        await a.close();
        await b.close();
      });
    }
  });
}
