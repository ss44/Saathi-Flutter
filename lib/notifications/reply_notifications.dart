import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class NotificationAdapter {
  bool get supported;
  Future<bool> requestPermission();
  Future<void> show(String id);
  Future<String?> consumePendingTap();
}

class AndroidNotificationAdapter implements NotificationAdapter {
  static const channel = MethodChannel('saathi/notifications');
  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  Future<bool> requestPermission() async =>
      await channel.invokeMethod<bool>('requestPermission') ?? false;
  @override
  Future<void> show(String id) =>
      channel.invokeMethod<void>('show', {'id': id});
  @override
  Future<String?> consumePendingTap() =>
      channel.invokeMethod<String>('consumePendingTap');
}

bool validConversationId(String id) =>
    RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id);

class ReplyNotifications extends ChangeNotifier with WidgetsBindingObserver {
  ReplyNotifications(this.preferences, {NotificationAdapter? adapter})
      : adapter = adapter ?? AndroidNotificationAdapter(),
        _enabled = preferences.get(preferenceKey) == true {
    _state = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    if (this.adapter is AndroidNotificationAdapter) {
      AndroidNotificationAdapter.channel.setMethodCallHandler((call) async {
        if (!_disposed && call.method == 'pendingTap') onResume?.call();
      });
    }
  }
  final SharedPreferences preferences;
  final NotificationAdapter adapter;
  AppLifecycleState? _state;
  bool _enabled;
  bool _disposed = false, _consuming = false, _consumeAgain = false;
  bool get supported => adapter.supported;
  static const preferenceKey = 'saathi.notifications.enabled.v1';
  bool get enabled => _enabled;
  VoidCallback? onResume;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _state = state;
    if (!_disposed && state == AppLifecycleState.resumed) onResume?.call();
  }

  Future<bool> setEnabled(bool value) async {
    try {
      if (value && (!supported || !await adapter.requestPermission())) {
        return false;
      }
      if (_disposed) return false;
      final saved = await preferences.setBool(preferenceKey, value);
      if (saved) _enabled = value;
      if (!_disposed) notifyListeners();
      return saved;
    } catch (_) {
      return false;
    }
  }

  Future<void> replyReceived(String id) async {
    if (_disposed ||
        !supported ||
        !enabled ||
        !validConversationId(id) ||
        (_state != AppLifecycleState.paused &&
            _state != AppLifecycleState.hidden)) {
      return;
    }
    // No async permission check here: native code rechecks permission and foreground
    // atomically with posting. Every call represents one new completed response.
    try {
      await adapter.show(id);
    } catch (_) {/* Never affect chat success. */}
  }

  Future<void> consumeTap(bool Function(String) openExisting) async {
    if (_disposed || !supported) return;
    if (_consuming) {
      _consumeAgain = true;
      return;
    }
    _consuming = true;
    try {
      // Drain: taps arriving during a consume must not be lost.
      do {
        _consumeAgain = false;
        while (!_disposed) {
          final id = await adapter.consumePendingTap();
          if (id == null || _disposed) break;
          if (validConversationId(id)) openExisting(id);
        }
      } while (!_disposed && _consumeAgain);
    } catch (_) {/* Unsupported bridge cannot break chat startup. */} finally {
      _consuming = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    onResume = null;
    if (adapter is AndroidNotificationAdapter) {
      AndroidNotificationAdapter.channel.setMethodCallHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
