import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';
import 'package:saathi/ui/chat_home.dart';
import 'organization_controller_integration_test.dart'
    show ControlledOrganizationStorage;
import 'runtime_recovery_test.dart' as recovery;
import 'runtime_flow_test.dart' show RuntimeFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'false abandon write must not remove uncertain journal from preference cache',
      () async {
    // Use the real preferences method-channel implementation, not its optimistic mock store.
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    final disk = <String, Object>{};
    var failJournal = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      if (call.method.startsWith('set')) {
        if (failJournal &&
            (args!['key'] as String)
                .endsWith(ChatController.preparedInputsKey)) {
          return false;
        }
        disk[args!['key'] as String] = args['value'] as Object;
        return true;
      }
      if (call.method == 'remove') {
        disk.remove(args!['key']);
        return true;
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final prefs = await SharedPreferences.getInstance();
    final store = SaathiStore(preferences: prefs, secrets: MemorySecrets());
    final c = ChatController(store,
        coreFactory: () => SaathiCore(
            client:
                MockClient((_) async => throw const SocketException('lost'))));
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', 'role');
    await c.send('uncertain');
    expect(c.uncertainInput, isNotNull);
    final before = prefs.getString(ChatController.preparedInputsKey)!;
    failJournal = true;
    await c.abandonHeldOutbox(c.current!);
    final cache = prefs.getString(ChatController.preparedInputsKey);
    debugPrint(
        'ABANDON_UI_UNCERTAIN=${c.uncertainInput != null} CACHE=$cache DISK=${disk['flutter.${ChatController.preparedInputsKey}']}');
    final restored = ChatController(store);
    await restored.load();
    debugPrint(
        'ABANDON_RECREATED_UNCERTAIN=${restored.uncertainInput != null}');
    c.dispose();
    restored.dispose();
    expect(cache, before,
        reason: 'A failed write must not erase recovered uncertainty');
  });
  testWidgets('failed visible metadata write then retry does not strand unread',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = ControlledOrganizationStorage(prefs);
    final c = ChatController(
        SaathiStore(preferences: prefs, secrets: MemorySecrets()),
        organizationStorage: storage);
    await c.load();
    await c
        .addConnection({'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture');
    await c.newSession(c.connections.single, 'model', '');
    final a = c.current!;
    a.messages.add(ChatMessage(
        role: 'model',
        content: 'Visible answer',
        id: 'reply',
        metadata: {'authoritativeCompletion': true}));
    await c.organization.recordCompletion(c.identityOf(a), 'reply');
    storage.fail = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(home: ChatHome(controller: c)));
    await tester.pumpAndSettle();
    expect(c.organization.entry(c.identityOf(a)).unread, isTrue);
    expect(c.organization.hasUnsavedChanges, isTrue);
    storage.fail = false;
    await c.retryOrganizationSave();
    await tester.pumpAndSettle();
    expect(c.organization.entry(c.identityOf(a)).unread, isFalse);
    debugPrint(
        'VISIBILITY_RETRY_UNREAD=${c.organization.entry(c.identityOf(a)).unread}');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  test('new local conversation must pause original accepted native followers',
      () async {
    HttpOverrides.global = null;
    final f = RuntimeFixture();
    await f.start();
    final c = await recovery.connect(f);
    try {
      await c.send('first');
      final a = c.current!;
      expect(c.submit('accepted follower'), isTrue);
      await c.newSession(c.connections.single, 'model', '');
      c.select(a);
      debugPrint('NEW_CHAT_ORIGINAL_QUEUE_STATUS=${c.queueStatus}');
      f.completed = true;
      await c.checkRunStatus();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      debugPrint(
          'NEW_CHAT_SUBMISSIONS=${f.submissions} OUTBOX=${c.outbox.length}');
      expect(f.submissions, 1,
          reason:
              'Switching away requires explicit Resume, not a second inference');
      expect(c.queueStatus, isNotNull);
      expect(c.outbox.single.text, 'accepted follower');
      expect(c.canResumeQueue, isTrue);
      c.resumeQueue();
      for (var i = 0; i < 20 && f.submissions < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(f.submissions, 2,
          reason:
              'Only explicit Resume admits the retained follower after A is terminal');
    } finally {
      c.dispose();
      await f.close();
    }
  });
}
