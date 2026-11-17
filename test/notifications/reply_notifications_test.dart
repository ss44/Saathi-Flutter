import 'dart:async';
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
  bool throwOnWrite = false;
  @override
  Object? get(String key) => _values[key];
  @override
  Future<bool> setBool(String key, bool value) async {
    // The plugin can update its local cache before a failed durable write.
    _values[key] = value;
    if (throwOnWrite) throw StateError('Controlled write failure');
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class InterleavedPreferences implements SharedPreferences {
  bool value = true;
  int writes = 0;
  final firstWrite = Completer<bool>();
  final compensationStarted = Completer<void>();
  final compensation = Completer<bool>();
  @override
  Object? get(String key) => value;
  @override
  Future<bool> setBool(String key, bool next) async {
    value = next;
    writes++;
    if (writes == 1) return firstWrite.future;
    if (next) {
      compensationStarted.complete();
      return compensation.future;
    }
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DelayedPermissionAdapter extends Adapter {
  final permission = Completer<bool>();
  int requests = 0;
  @override
  Future<bool> requestPermission() {
    requests++;
    return permission.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('overlapping opt-outs cannot race a failed write and its compensation',
      () async {
    final preferences = InterleavedPreferences();
    final notifications = ReplyNotifications(preferences, adapter: Adapter());
    addTearDown(notifications.dispose);
    final first = notifications.setEnabled(false);
    try {
      expect(await notifications.setEnabled(false), isFalse);
      expect(preferences.writes, 1);
      preferences.firstWrite.complete(false);
      await preferences.compensationStarted.future;
      expect(await notifications.setEnabled(false), isFalse);
      expect(preferences.writes, 2);
      preferences.compensation.complete(true);
      expect(await first, isFalse);
      expect(notifications.enabled, isTrue);
      final afterFailure = ReplyNotifications(preferences, adapter: Adapter());
      expect(afterFailure.enabled, isTrue);
      afterFailure.dispose();
      expect(await notifications.setEnabled(false), isTrue);
      expect(notifications.enabled, isFalse);
      final afterSuccess = ReplyNotifications(preferences, adapter: Adapter());
      expect(afterSuccess.enabled, isFalse);
      afterSuccess.dispose();
    } finally {
      if (!preferences.firstWrite.isCompleted) {
        preferences.firstWrite.complete(false);
      }
      if (!preferences.compensation.isCompleted) {
        preferences.compensation.complete(true);
      }
      await first;
    }
  });
  for (final granted in [false, true]) {
    test(
        'permission wait rejects opposite changes and releases, granted=$granted',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final adapter = DelayedPermissionAdapter();
      final notifications = ReplyNotifications(preferences, adapter: adapter);
      addTearDown(notifications.dispose);
      final enabling = notifications.setEnabled(true);
      try {
        expect(await notifications.setEnabled(false), isFalse);
        expect(adapter.requests, 1);
        adapter.permission.complete(granted);
        expect(await enabling, granted);
        expect(notifications.enabled, granted);
        final afterPermission =
            ReplyNotifications(preferences, adapter: Adapter());
        expect(afterPermission.enabled, granted);
        afterPermission.dispose();
        expect(await notifications.setEnabled(false), isTrue);
        final recreated = ReplyNotifications(preferences, adapter: Adapter());
        expect(recreated.enabled, isFalse);
        recreated.dispose();
      } finally {
        if (!adapter.permission.isCompleted) adapter.permission.complete(false);
        await enabling;
      }
    });
  }
  test('failed preference storage does not enable notifications', () async {
    final n = ReplyNotifications(FailingPreferences(), adapter: Adapter());
    expect(await n.setEnabled(true), isFalse);
    expect(n.enabled, isFalse);
    n.dispose();
  });
  test('failed opt-in does not leak through the preference cache on recreation',
      () async {
    final preferences = FailingPreferences();
    final first = ReplyNotifications(preferences, adapter: Adapter());
    expect(await first.setEnabled(true), isFalse);
    first.dispose();
    final recreated = ReplyNotifications(preferences, adapter: Adapter());
    expect(recreated.enabled, isFalse);
    recreated.dispose();
  });
  for (final throws in [false, true]) {
    test('failed opt-out restores cache on recreation, throws=$throws',
        () async {
      final preferences = FailingPreferences()..throwOnWrite = throws;
      preferences._values[ReplyNotifications.preferenceKey] = true;
      final first = ReplyNotifications(preferences, adapter: Adapter());
      expect(await first.setEnabled(false), isFalse);
      first.dispose();
      final recreated = ReplyNotifications(preferences, adapter: Adapter());
      expect(recreated.enabled, isTrue);
      recreated.dispose();
    });
  }
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
