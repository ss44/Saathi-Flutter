import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/notifications/reply_notifications.dart';

class Adapter implements NotificationAdapter {
  @override
  bool get supported => true;
  bool allowed = true;
  bool throwsOnShow = false;
  final shown = <String>[];
  String? tap;
  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<void> show(String id) async {
    if (throwsOnShow) throw StateError('OS failure');
    shown.add(id);
  }

  @override
  Future<String?> consumePendingTap() async {
    final id = tap;
    tap = null;
    return id;
  }
}

class FailingPreferences implements SharedPreferences {
  final _values = <String, Object>{};
  @override
  Object? get(String key) => _values[key];
  @override
  Future<bool> setBool(String key, bool value) async {
    // The plugin can update its local cache before a failed durable write.
    _values[key] = value;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('failed preference storage does not enable notifications', () async {
    final n = ReplyNotifications(FailingPreferences(), adapter: Adapter());
    expect(await n.setEnabled(true), isFalse);
    expect(n.enabled, isFalse);
    n.dispose();
  });
  test('only paused or hidden responses notify; resume and disposal suppress',
      () async {
    SharedPreferences.setMockInitialValues({});
    final adapter = Adapter();
    final n = ReplyNotifications(await SharedPreferences.getInstance(),
        adapter: adapter);
    await n.setEnabled(true);
    for (final state in [
      AppLifecycleState.detached,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      n.didChangeAppLifecycleState(state);
      await n.replyReceived('one');
    }
    expect(adapter.shown, isEmpty);
    n.didChangeAppLifecycleState(AppLifecycleState.paused);
    await n.replyReceived('one');
    n.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await n.replyReceived('two');
    expect(adapter.shown, ['one', 'two']);
    n.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await n.replyReceived('three');
    n.dispose();
    await n.replyReceived('four');
    expect(adapter.shown, ['one', 'two']);
  });
  test('opt-in uses a namespaced boolean and ignores invalid stored values',
      () async {
    SharedPreferences.setMockInitialValues({'notifications.enabled': true});
    final preferences = await SharedPreferences.getInstance();
    final n = ReplyNotifications(preferences, adapter: Adapter());
    expect(n.enabled, isFalse);
    expect(await n.setEnabled(true), isTrue);
    expect(preferences.getBool('saathi.notifications.enabled.v1'), isTrue);
    await preferences.setString('saathi.notifications.enabled.v1', 'invalid');
    n.dispose();
    final reloaded = ReplyNotifications(preferences, adapter: Adapter());
    expect(reloaded.enabled, isFalse);
    reloaded.didChangeAppLifecycleState(AppLifecycleState.paused);
    await reloaded.replyReceived('one');
    reloaded.dispose();
  });
  test('default off, permission denial, adapter isolation and tap consumption',
      () async {
    SharedPreferences.setMockInitialValues({});
    final adapter = Adapter()..allowed = false;
    final n = ReplyNotifications(await SharedPreferences.getInstance(),
        adapter: adapter);
    expect(n.enabled, isFalse);
    expect(await n.setEnabled(true), isFalse);
    n.didChangeAppLifecycleState(AppLifecycleState.paused);
    await n.replyReceived('one');
    expect(adapter.shown, isEmpty);
    adapter.allowed = true;
    await n.setEnabled(true);
    adapter.throwsOnShow = true;
    await n.replyReceived('one');
    final opened = <String>[];
    adapter.tap = 'existing';
    await n.consumeTap((id) {
      opened.add(id);
      return true;
    });
    await n.consumeTap((id) {
      opened.add(id);
      return true;
    });
    adapter.tap = '../foreign';
    await n.consumeTap((id) {
      opened.add(id);
      return true;
    });
    expect(opened, ['existing']);
    n.dispose();
  });
}
