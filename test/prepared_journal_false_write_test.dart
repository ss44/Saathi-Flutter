import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:saathi/core/saathi_core.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/ui/chat_controller.dart';

class JournalChannel {
  final disk = <String, Object>{};
  bool Function(String value) fail = (_) => false;
  int posts = 0;
  late SaathiStore store;
  static const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  Future<ChatController> start() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        MethodChannelSharedPreferencesStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map?;
      if (call.method == 'getAll') return Map<String, Object>.from(disk);
      if (call.method.startsWith('set')) {
        if (args!['key'] == 'flutter.${ChatController.preparedInputsKey}' &&
            fail(args['value'] as String)) {
          return false;
        }
        disk[args['key'] as String] = args['value'] as Object;
      } else if (call.method == 'remove') {
        disk.remove(args!['key']);
      }
      return true;
    });
    store = SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: MemorySecrets());
    final c = controller();
    await c.load();
    await c.addConnection(
        {'id': 'a', 'name': 'A', 'type': 'openai'}, 'fixture-only');
    await c.newSession(c.connections.single, 'model', 'Immutable prompt');
    return c;
  }

  ChatController controller() => ChatController(store,
      coreFactory: () => SaathiCore(client: MockClient((_) async {
            posts++;
            throw const SocketException('fixture lost reply');
          })));
  String? get cache =>
      store.preferences.getString(ChatController.preparedInputsKey);
  String? get durable =>
      disk['flutter.${ChatController.preparedInputsKey}'] as String?;
  Future<ChatController> restore() async {
    final c = controller();
    await c.load();
    addTearDown(c.dispose);
    return c;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late JournalChannel f;
  setUp(() => f = JournalChannel());
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JournalChannel.channel, null);
    SharedPreferences.setMockInitialValues({});
  });

  test('false prepare write restores absent cache and cannot dispatch',
      () async {
    final c = await f.start();
    addTearDown(c.dispose);
    f.fail = (_) => true;
    expect(await c.send('prepare fails'), isFalse);
    expect(f.posts, 0);
    expect(f.cache, isNull);
    expect(f.durable, isNull);
    final restored = await f.restore();
    expect(restored.uncertainInput, isNull);
    expect(restored.outbox, isEmpty);
    f.fail = (_) => false;
    await c.send('explicit retry');
    expect(f.posts, 1);
    expect(c.uncertainInput, isNotNull);
  });

  test('false dispatch journal restores exact prepared source and held restart',
      () async {
    final c = await f.start();
    addTearDown(c.dispose);
    f.fail = (value) => value.contains('"state":"dispatched"');
    expect(await c.send('never posted'), isFalse);
    expect(f.posts, 0);
    expect(f.cache, f.durable);
    expect((jsonDecode(f.cache!) as List).single['state'], 'prepared');
    final restored = await f.restore();
    expect(restored.uncertainInput, isNull);
    expect(restored.outbox.single.text, 'never posted');
    expect(restored.outbox.single.captured.instructions, 'Immutable prompt');
    expect(restored.queueStatus, isNotNull);
    restored.resumeQueue();
    for (var i = 0; i < 15 && restored.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(f.posts, 0);
    expect(f.cache, f.durable);
    expect(restored.outbox, hasLength(1));
    f.fail = (_) => false;
    restored.resumeQueue();
    for (var i = 0; i < 15 && restored.uncertainInput == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(f.posts, 1);
    expect(restored.uncertainInput, isNotNull);
  });

  test(
      'false abandon and failed retry retain exact unknown record on recreation',
      () async {
    final c = await f.start();
    addTearDown(c.dispose);
    await c.send('uncertain');
    final prior = f.cache;
    final replyId = c.uncertainInput!.replyId;
    f.fail = (_) => true;
    for (var i = 0; i < 2; i++) {
      await c.abandonHeldOutbox(c.current!);
      expect(c.uncertainInput!.replyId, replyId);
      expect(f.cache, prior);
      expect(f.durable, prior);
    }
    final restored = await f.restore();
    expect(restored.uncertainInput!.replyId, replyId);
    expect(restored.uncertainInput!.captured.instructions, 'Immutable prompt');
    expect(restored.canResumeQueue, isFalse);
    expect(restored.submit('duplicate'), isFalse);
    expect(await restored.send('duplicate'), isFalse);
    expect(f.posts, 1);
    f.fail = (_) => false;
    await restored.abandonHeldOutbox(restored.current!);
    expect(restored.uncertainInput, isNull);
    expect(f.cache, '[]');
    expect(f.durable, '[]');
  });

  test(
      'failed abandon cannot bypass original source binding after key revision change',
      () async {
    final c = await f.start();
    addTearDown(c.dispose);
    final original = c.current!;
    await c.addConnection({
      'id': 'b',
      'name': 'B',
      'type': 'openai',
      'url': 'https://independent.test'
    }, 'other');
    await c.newSession(c.connections.last, 'model', '');
    final independent = c.current!;
    c.select(original);
    await c.send('uncertain');
    final prior = f.cache;
    f.fail = (_) => true;
    await c.abandonHeldOutbox(c.current!);
    await c.updateConnection('a', c.connections.first,
        apiKey: 'rotated-fixture');
    expect(f.cache, prior);
    // Storage recovers before recreation; the failed discard never removed
    // evidence, and loading may now durably quarantine the changed source.
    f.fail = (_) => false;
    final restored = await f.restore();
    restored.select(restored.sessions.singleWhere((s) => s.id == original.id));
    expect(restored.readOnly, isTrue);
    expect((jsonDecode(f.cache!) as List).single['text'],
        (jsonDecode(prior!) as List).single['text']);
    expect(await restored.send('do not redirect'), isFalse);
    expect(f.posts, 1);
    restored
        .select(restored.sessions.singleWhere((s) => s.id == independent.id));
    expect(restored.readOnly, isFalse);
    expect(restored.canChangeConnections, isTrue);
  });

  test('quarantine publication and explicit discard failures retain evidence',
      () async {
    final c = await f.start();
    addTearDown(c.dispose);
    await c.send('retained across quarantine failures');
    await c.updateConnection('a', c.connections.single, apiKey: 'replacement');
    final prior = f.durable;
    f.fail = (_) => true;
    final blocked = await f.restore();
    expect(blocked.readOnly, isTrue);
    expect(blocked.canChangeConnections, isFalse);
    expect(f.durable, prior);
    expect(f.cache, prior);
    expect(f.posts, 1);
    f.fail = (_) => false;
    final quarantined = await f.restore();
    expect(quarantined.readOnly, isTrue);
    expect(quarantined.canChangeConnections, isTrue);
    final held = f.durable;
    expect((jsonDecode(held!) as List).single['quarantined'], isTrue);
    f.fail = (_) => true;
    await quarantined.abandonHeldOutbox(quarantined.current!);
    expect(quarantined.error, contains('could not be removed from storage'));
    expect(quarantined.uncertainInput!.text,
        'retained across quarantine failures');
    expect(quarantined.readOnly, isTrue);
    expect(f.cache, held);
    expect(f.durable, held);
    expect(f.posts, 1);
  });
}
