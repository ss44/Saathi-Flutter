import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_service.dart';
import 'update_installer_stub.dart'
    if (dart.library.io) 'update_installer_io.dart' as native;

enum UpdateStatus {
  disabled,
  idle,
  checking,
  upToDate,
  available,
  downloading,
  handedOff,
  error,
}

typedef UpdateInstaller = Future<bool> Function(VerifiedUpdate update);
typedef UpdateUrlOpener = Future<bool> Function(Uri url);

/// Own one instance at app scope, call start once, then dispose with its owner.
/// Checks are automatic; downloads and external UI ALWAYS require explicit consent.
class SaathiUpdateController extends ChangeNotifier
    with WidgetsBindingObserver {
  SaathiUpdateController(
      {required this.service,
      UpdateInstaller? installer,
      UpdateUrlOpener? openUrl,
      this.checkInterval = const Duration(hours: 6),
      DateTime Function()? clock})
      : _installer = installer ?? _nativeInstall,
        _openUrl = openUrl ?? _launch,
        _clock = clock ?? DateTime.now,
        _status =
            service.config.enabled ? UpdateStatus.idle : UpdateStatus.disabled;

  final SaathiUpdateService service;
  final Duration checkInterval;
  final UpdateInstaller _installer;
  final UpdateUrlOpener _openUrl;
  final DateTime Function() _clock;
  bool _started = false, _disposed = false;
  bool _busy = false;
  Future<void>? _pendingCheck;
  DateTime? _lastCheck;
  UpdateStatus _status;
  UpdateOffer? _offer;
  String? _error;
  double _progress = 0;

  UpdateStatus get status => _status;
  UpdateOffer? get offer => _offer;
  String? get error => _error;
  double get progress => _progress;
  bool get supportsAndroidInstall =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(check());
  }

  Future<void> check({bool force = false}) {
    if (_disposed || !service.config.enabled || _busy) return Future.value();
    if (_pendingCheck != null) return _pendingCheck!;
    if (!force &&
        _lastCheck != null &&
        _clock().difference(_lastCheck!) < checkInterval) {
      return Future.value();
    }
    final completer = Completer<void>();
    _pendingCheck = completer.future;
    unawaited(_runCheck().whenComplete(() {
      _pendingCheck = null;
      completer.complete();
    }));
    return completer.future;
  }

  Future<void> _runCheck() async {
    _lastCheck = _clock();
    _error = null;
    _setStatus(UpdateStatus.checking);
    try {
      final result = await service.check();
      if (_disposed) return;
      _offer = result;
      _setStatus(
          result == null ? UpdateStatus.upToDate : UpdateStatus.available);
    } catch (_) {
      // No URLs, signed CDN query strings or raw remote content in user errors.
      _error = 'Could not securely check for updates. Try again later.';
      _setStatus(UpdateStatus.error);
    }
  }

  Future<void> installAndroid({required bool userConsented}) async {
    if (!userConsented ||
        _disposed ||
        _busy ||
        _pendingCheck != null ||
        _offer == null) {
      return;
    }
    _busy = true;
    _error = null;
    _progress = 0;
    _setStatus(UpdateStatus.downloading);
    try {
      if (service.platform != 'android') {
        throw const UpdateException('Not an Android artifact');
      }
      final verified = await service.download(_offer!, onProgress: (progress) {
        _progress = progress;
        if (!_disposed) notifyListeners();
      });
      if (_disposed) return;
      final opened = await _installer(verified);
      if (!opened) throw const UpdateException('Installer did not open');
      _setStatus(UpdateStatus.handedOff);
    } on PlatformException catch (error) {
      _error = error.code == 'install_permission_required'
          ? 'Allow updates from Saathi in Android settings, then tap Install again.'
          : 'Android could not open the installer. The update was not installed.';
      _setStatus(UpdateStatus.error);
    } catch (_) {
      _error =
          'Update was not installed. Verification or installer handoff failed.';
      _setStatus(UpdateStatus.error);
    } finally {
      _busy = false;
    }
  }

  /// Desktop/manual fallback. Does not claim to verify anything downloaded by
  /// the browser, and does not execute or silently install remote binaries.
  Future<void> openReleasePage({required bool userConsented}) async {
    if (!userConsented ||
        _disposed ||
        _busy ||
        _pendingCheck != null ||
        _offer == null) {
      return;
    }
    _busy = true;
    _error = null;
    try {
      service.validateOffer(_offer!);
      if (!await _openUrl(_offer!.releaseUrl)) {
        throw const UpdateException('Browser did not open');
      }
      _setStatus(UpdateStatus.handedOff);
    } catch (_) {
      _error = 'Could not open the release page.';
      _setStatus(UpdateStatus.error);
    } finally {
      _busy = false;
    }
  }

  void _setStatus(UpdateStatus value) {
    if (_disposed) return;
    _status = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    service.close();
    super.dispose();
  }

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  static Future<bool> _nativeInstall(VerifiedUpdate update) =>
      native.installVerifiedAndroidUpdate(update);
}
