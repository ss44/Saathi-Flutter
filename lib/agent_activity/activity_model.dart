import 'dart:async';

/// Runtime-neutral statuses. Only the adapter may supply parent status.
enum ActivityStatus {
  queued,
  running,
  waitingApproval,
  answerNeeded,
  stopping,
  interrupted,
  completed,
  failed,
  cancelled,
  unknown;

  bool get terminal =>
      this == completed ||
      this == failed ||
      this == cancelled ||
      this == interrupted;
  bool get needsAttention => this == waitingApproval || this == answerNeeded;
  String get label => switch (this) {
        waitingApproval => 'Waiting for approval',
        answerNeeded => 'Answer needed',
        stopping => 'Stopping',
        interrupted => 'Interrupted',
        unknown => 'Status unknown',
        queued => 'Queued',
        running => 'Running',
        completed => 'Completed',
        failed => 'Failed',
        cancelled => 'Cancelled',
      };
}

/// An opaque capability created from trusted local connection/chat metadata.
/// Never construct a binding from an SSE payload. A replacement connection
/// revision revokes old bindings, including callbacks held by an open panel.
class ActivityBinding {
  ActivityBinding._(this.connectionId, this.revision, this.connectionName,
      this.localChatId, this.runId, this.title);
  final String connectionId,
      revision,
      connectionName,
      localChatId,
      runId,
      title;
}

class ChildActivity {
  const ChildActivity(
      {this.subagentId,
      this.childSessionId,
      this.delegationId,
      required this.goal,
      required this.summary,
      required this.status});
  final String? subagentId, childSessionId, delegationId;
  final String goal, summary;
  final ActivityStatus status;
}

class ParentActivity {
  const ParentActivity(this.binding, this.status, this.children,
      this.batchTaskCount, this.childrenOverflow);
  final ActivityBinding binding;
  final ActivityStatus status;
  final List<ChildActivity> children;
  final bool childrenOverflow;

  /// Informational only: never added to the number of observed children.
  final int? batchTaskCount;
  bool get visible =>
      !status.terminal || children.any((c) => !c.status.terminal);
}

class _Parent {
  _Parent(this.binding);
  final ActivityBinding binding;
  ActivityStatus status = ActivityStatus.unknown;
  final List<ChildActivity> children = [];
  bool childrenOverflow = false;
  int? seq, batchTaskCount;
  final List<String> cursors = [];
  ParentActivity get snapshot => ParentActivity(binding, status,
      List.unmodifiable(children), batchTaskCount, childrenOverflow);
}

/// No networking, persistence, Flutter, tool payload retention, or child control.
/// Adapter owns authoritative polling/SSE and must call disconnected on loss.
class ActivityModel {
  ActivityModel(
      {required String Function(String) redact,
      this.supported = true,
      this.maxParents = 64,
      this.maxChildren = 128})
      : _redact = redact {
    if (maxParents < 1 || maxChildren < 1) {
      throw ArgumentError('Positive limits required');
    }
  }
  final String Function(String) _redact;
  final bool supported;
  final int maxParents, maxChildren;
  final _changes = StreamController<void>.broadcast(sync: true);
  final List<_Parent> _parents = [];
  bool _disposed = false;

  /// Sticky uncertainty: some active records exceeded retention; reconcile externally.
  bool parentsOverflow = false;
  Stream<void> get changes => _changes.stream;
  List<ParentActivity> get parents =>
      List.unmodifiable(_parents.map((p) => p.snapshot));
  List<ParentActivity> get visibleParents =>
      supported ? List.unmodifiable(parents.where((p) => p.visible)) : const [];

  String _safe(Object? value, [int limit = 160]) {
    if (value is! String) return '';
    // Never disclose a prefix of a secret the redactor cannot see in full.
    if (value.length > 2048) return '';
    String result;
    try {
      result = _redact(value);
    } catch (_) {
      return '';
    }
    result = result
        .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), ' ')
        .trim();
    return result.length > limit ? '${result.substring(0, limit)}…' : result;
  }

  String? _id(Object? v) => v is String &&
          v.isNotEmpty &&
          v.length <= 256 &&
          !RegExp(r'[\x00-\x20\x7f]').hasMatch(v)
      ? v
      : null;
  void _emit() {
    if (!_disposed) _changes.add(null);
  }

  _Parent? _find(ActivityBinding b) {
    if (_disposed) return null;
    for (final p in _parents) {
      if (identical(p.binding, b)) return p;
    }
    return null;
  }

  bool canNavigate(ActivityBinding binding) => _find(binding) != null;

  ActivityBinding bind(
      {required String connectionId,
      required String revision,
      required String connectionName,
      required String localChatId,
      required String runId,
      required String title}) {
    if (_disposed) throw StateError('Activity model disposed');
    _parents.removeWhere((p) =>
        p.binding.connectionId == connectionId &&
        p.binding.revision != revision);
    for (final p in _parents) {
      final b = p.binding;
      if (b.connectionId == connectionId &&
          b.revision == revision &&
          b.localChatId == localChatId &&
          b.runId == runId) {
        return b;
      }
    }
    if (_parents.length >= maxParents) {
      final terminal = _parents.indexWhere((p) => !p.snapshot.visible);
      if (terminal >= 0) _parents.removeAt(terminal);
    }
    final b = ActivityBinding._(connectionId, revision,
        _safe(connectionName, 64), localChatId, runId, _safe(title));
    if (_parents.length < maxParents) {
      _parents.add(_Parent(b));
    } else {
      parentsOverflow = true;
    }
    _emit();
    return b;
  }

  void removeBinding(ActivityBinding binding) {
    _parents.removeWhere((p) => identical(p.binding, binding));
    _emit();
  }

  void removeConnection(String connectionId) {
    _parents.removeWhere((p) => p.binding.connectionId == connectionId);
    _emit();
  }

  void updateStatus(ActivityBinding binding, ActivityStatus status) {
    final p = _find(binding);
    if (p == null || p.status.terminal) return;
    p.status = status;
    if (status.terminal) _uncertain(p);
    _emit();
  }

  void _uncertain(_Parent p) {
    for (var i = 0; i < p.children.length; i++) {
      final c = p.children[i];
      if (!c.status.terminal) {
        p.children[i] = ChildActivity(
            subagentId: c.subagentId,
            childSessionId: c.childSessionId,
            delegationId: c.delegationId,
            goal: c.goal,
            summary: c.summary,
            status: ActivityStatus.unknown);
      }
    }
  }

  void disconnected(ActivityBinding binding) {
    final p = _find(binding);
    if (p == null) return;
    if (!p.status.terminal) p.status = ActivityStatus.unknown;
    _uncertain(p);
    _emit();
  }

  /// Pass decoded JSON data plus the transport's SSE id, not named-event text.
  /// Payload run_id must match the separate, already trusted binding.
  void event(ActivityBinding binding, Map<String, Object?> data,
      {String? cursor}) {
    final p = _find(binding);
    if (p == null || data['run_id'] != binding.runId) return;
    final rawSeq = data['seq'];
    if (rawSeq != null && (rawSeq is! int || rawSeq < 0)) return;
    final seq = rawSeq is int ? rawSeq : null;
    final safeCursor = _id(cursor);
    if ((seq != null && p.seq != null && seq <= p.seq!) ||
        (safeCursor != null && p.cursors.contains(safeCursor))) {
      return;
    }
    final gap = seq != null && p.seq != null && seq > p.seq! + 1;
    if (seq != null) p.seq = seq;
    if (safeCursor != null) {
      p.cursors.add(safeCursor);
      if (p.cursors.length > 128) p.cursors.removeAt(0);
    }
    if (gap) {
      if (!p.status.terminal) p.status = ActivityStatus.unknown;
      _uncertain(p);
    }
    final type = data['event'];
    if (type != 'subagent.start' && type != 'subagent.complete') {
      _emit();
      return;
    }
    final count = data['task_count'];
    if (count is int && count > 0 && count <= 10000) p.batchTaskCount = count;
    final sub = _id(data['subagent_id']),
        session = _id(data['child_session_id']),
        delegation = _id(data['delegation_id']);
    // A batch announcement or task_index alone is not a child identity.
    if (sub == null && session == null) {
      _emit();
      return;
    }
    final index = p.children.indexWhere((c) =>
        // delegation is a batch identity and cannot identify one child by itself.
        (c.delegationId == null ||
            delegation == null ||
            c.delegationId == delegation) &&
        ((sub != null && c.subagentId == sub) ||
            (session != null && c.childSessionId == session)));
    final old = index < 0 ? null : p.children[index];
    if (old != null && old.status.terminal) return;
    var status = ActivityStatus.unknown;
    if (type == 'subagent.start') {
      status = p.status.terminal || p.status == ActivityStatus.unknown || gap
          ? ActivityStatus.unknown
          : ActivityStatus.running;
    } else {
      status = switch (data['status']) {
        'completed' || 'success' => ActivityStatus.completed,
        'failed' || 'error' || 'timeout' => ActivityStatus.failed,
        'cancelled' || 'canceled' => ActivityStatus.cancelled,
        'interrupted' => ActivityStatus.interrupted,
        'stopping' => ActivityStatus.stopping,
        'waiting_for_approval' => ActivityStatus.waitingApproval,
        'answer_needed' || 'waiting_for_answer' => ActivityStatus.answerNeeded,
        _ => ActivityStatus.unknown,
      };
    }
    final goal = _safe(data['goal']);
    final child = ChildActivity(
        subagentId: sub ?? old?.subagentId,
        childSessionId: session ?? old?.childSessionId,
        delegationId: delegation ?? old?.delegationId,
        goal: goal.isNotEmpty ? goal : old?.goal ?? 'Child task',
        summary: _safe(data['summary']),
        status: status);
    if (index >= 0) {
      p.children[index] = child;
    } else {
      if (p.children.length >= maxChildren) {
        final terminal = p.children.indexWhere((c) => c.status.terminal);
        if (terminal >= 0) p.children.removeAt(terminal);
      }
      if (p.children.length < maxChildren) {
        p.children.add(child);
      } else if (!child.status.terminal) {
        p.childrenOverflow = true;
      }
    }
    _emit();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _parents.clear();
    _changes.close();
  }
}
