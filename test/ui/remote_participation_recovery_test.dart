import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'package:saathi/ui/conversation_servers.dart';

import '../runtime_flow_test.dart' show RuntimeFixture;
import '../runtime_recovery_test.dart' show connect;
import 'remote_participation_test.dart' show network;

void main() {
  for (final restart in [false, true]) {
    testWidgets(
        'drawer opens unknown original work without resending restart=$restart',
        (t) async {
      HttpOverrides.global = null;
      final host = RuntimeFixture()..loseFirstAck = true;
      late ChatController controller;
      late String localId, operationKey;
      late List<String> originalMessages;
      await t.runAsync(() async {
        await host.start();
        controller = await connect(host);
        await controller.send('Uncertain original input');
        expect(host.submissions, 1);
        expect(controller.currentRun!.runId, isNull);
        localId = controller.current!.id;
        operationKey = controller.currentRun!.key;
        originalMessages =
            controller.current!.messages.map((m) => m.content).toList();
        if (restart) {
          final store = controller.store;
          controller.dispose();
          controller = ChatController(store);
          await controller.load();
        }
      });
      addTearDown(host.close);
      addTearDown(() => controller.dispose());
      controller.current = null;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(MaterialApp(home: ChatHome(controller: controller)));
      await t.tap(find.byTooltip('Open navigation menu'));
      await network(t);
      final duplicateRemoteRow = find.descendant(
          of: find.byType(ConversationServer),
          matching: find.text('External chat'));
      expect(duplicateRemoteRow, findsNothing);
      final localRow = find.descendant(
          of: find.byType(Drawer), matching: find.text('External chat'));
      await t.ensureVisible(localRow);
      await t.tap(localRow);
      await network(t);
      // Unknown work may keep a live progress indicator; settle only navigation.
      await t.pump(const Duration(milliseconds: 400));
      await network(t);
      expect(find.text('Continue conversation'), findsNothing);
      expect(find.byKey(const Key('composer')).hitTestable(), findsOneWidget);
      expect(controller.current!.id, localId);
      expect(controller.current!.connectionId, 'h');
      expect(controller.currentRun!.key, operationKey);
      expect(controller.currentRun!.runId, isNull);
      expect(controller.runPending, isTrue);
      expect(
          controller.current!.messages.map((m) => m.content), originalMessages);
      expect(host.submissions, 1);
      expect(controller.sessions, hasLength(1));
      await t.pumpWidget(const SizedBox());
      await network(t);
    });
  }
}
