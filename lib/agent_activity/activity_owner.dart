import 'dart:async';
import 'package:http/http.dart' as http;
import '../agent_runs/run_client.dart';
import '../ui/chat_controller.dart';
import 'activity_model.dart';
import 'activity_transport.dart';

class _Attachment {
  _Attachment(this.scope, this.binding);
  final ScopedRunSnapshot scope;
  final ActivityBinding binding;
  ActivityTransport? transport;
  http.Client? client;
  String? cursor;
  int generation = 0;
  bool attempted = false;
}

/// ChatHome-owned read-only telemetry. Native Runs owns status recovery/polling.
class ActivityOwner {
  ActivityOwner(this.controller) {
    model = ActivityModel(redact: (text) {
      for (final key in _keys.values) {
        if (key.isNotEmpty) text = text.replaceAll(key, '[redacted]');
      }
      return text;
    });
    _updates = controller.scopedRunSnapshots.listen(_accept, onDone: dispose);
    controller.addListener(_validate);
  }
  final ChatController controller;
  late final ActivityModel model;
  late final StreamSubscription<ScopedRunSnapshot> _updates;
  final _attachments = <_Attachment>[];
  final _keys = <_Attachment, String>{};
  bool _disposed = false, _paused = false;

  static ActivityStatus status(String value) => switch (value) {
        'queued' => ActivityStatus.queued,
        'started' || 'running' => ActivityStatus.running,
        'waiting_for_approval' => ActivityStatus.waitingApproval,
        'answer_needed' || 'waiting_for_answer' => ActivityStatus.answerNeeded,
        'stopping' => ActivityStatus.stopping,
        'interrupted' => ActivityStatus.interrupted,
        'completed' => ActivityStatus.completed,
        'failed' => ActivityStatus.failed,
        'cancelled' => ActivityStatus.cancelled,
        _ => ActivityStatus.unknown,
      };

  bool _valid(_Attachment a) =>
      !_disposed && !_paused && a.scope.isObservable();
  void _accept(ScopedRunSnapshot s) {
    if (_disposed || !s.isObservable() || s.snapshot.runId == null) return;
    var a = _attachments
        .where((a) =>
            identical(a.scope.connectionRevision, s.connectionRevision) &&
            a.scope.localChatId == s.localChatId &&
            a.binding.runId == s.snapshot.runId)
        .firstOrNull;
    if (a == null) {
      final connection = s.originalConnection;
      if (connection == null) return;
      final session =
          controller.sessions.where((c) => c.id == s.localChatId).firstOrNull;
      if (session == null) return;
      final b = model.bind(
          connectionId: s.connectionId,
          revision: identityHashCode(s.connectionRevision).toString(),
          connectionName: connection['name'] as String? ?? '',
          localChatId: s.localChatId,
          runId: s.snapshot.runId!,
          title: session.title);
      if (!model.canNavigate(b)) return;
      a = _Attachment(s, b);
      _attachments.add(a);
    }
    model.updateStatus(a.binding, status(s.snapshot.status));

    if (!a.attempted && s.eventsSupported) unawaited(_connect(a));
  }

  Future<void> _connect(_Attachment a) async {
    if (!_valid(a) || a.attempted || !a.scope.eventsSupported) return;
    a.attempted = true;
    final generation = ++a.generation;
    try {
      final key =
          await controller.store.secrets.read(a.scope.connectionId) ?? '';

      if (!_valid(a) || generation != a.generation) return;
      final root = a.scope.originalConnection!['url'] as String;
      final authority = RunClient(root, key);
      final base = authority.base;
      final matches =
          authority.scope == a.scope.originalAuthority['credentialScope'] &&
              base.toString() == a.scope.originalAuthority['origin'];
      authority.close();
      if (!matches || !_valid(a)) throw StateError('Authority unavailable');
      _keys[a] = key;
      final client = http.Client();
      a.client = client;
      final transport = ActivityTransport(
          origin: base.replace(path: ''),
          profile: base.path.isEmpty ? null : base.pathSegments.last,
          bearerKey: key,
          isCurrent: () => _valid(a) && generation == a.generation,
          eventsSupported: true,
          client: client);
      a.transport = transport;
      transport.connect(a.binding.runId, lastEventId: a.cursor).listen((e) {
        if (!_valid(a) || generation != a.generation) return;
        a.cursor = e.cursor;
        controller.observeRunEvent(a.scope, e.data, cursor: e.cursor);
        model.event(a.binding, e.data, cursor: e.cursor);
      }, onError: (Object _) {
        if (generation == a.generation) {
          model.disconnected(a.binding);
          controller.runStreamDisconnected(a.scope);
        }
      }, onDone: () {
        if (generation == a.generation) {
          model.disconnected(a.binding);
          controller.runStreamDisconnected(a.scope);
        }
      });
    } catch (_) {
      if (!_disposed && generation == a.generation) {
        model.disconnected(a.binding);
      }
    }
  }

  void _stop(_Attachment a) {
    a.generation++;
    a.cursor = a.transport?.cursor ?? a.cursor;
    if (a.transport != null) unawaited(a.transport!.close());
    a.client?.close();
    a.transport = null;
    a.client = null;
    _keys.remove(a);
    model.disconnected(a.binding);
  }

  void _validate() {
    if (_disposed || _paused) return;
    for (final a in _attachments.toList()) {
      if (!a.scope.isObservable() || !model.canNavigate(a.binding)) {
        _stop(a);
        _attachments.remove(a);
        model.removeBinding(a.binding);
      }
    }
  }

  /// Explicit safe reconnect only; no automatic retry on done/error/gaps.
  void setPaused(bool paused) {
    if (_disposed || paused == _paused) return;
    _paused = paused;
    for (final a in _attachments) {
      if (paused) {
        _stop(a);
      } else {
        a.attempted = false;
        unawaited(_connect(a));
      }
    }
    if (!paused) _validate();
  }

  Map<String, dynamic>? connectionFor(ActivityBinding binding) {
    final a =
        _attachments.where((a) => identical(a.binding, binding)).firstOrNull;
    return a != null && _valid(a) && model.canNavigate(binding)
        ? a.scope.originalConnection
        : null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_validate);
    unawaited(_updates.cancel());
    for (final a in _attachments) {
      _stop(a);
    }
    _attachments.clear();
    model.dispose();
  }
}
