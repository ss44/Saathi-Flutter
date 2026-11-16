import 'dart:convert';
import 'package:flutter/foundation.dart';

enum ControlAction { approval, clarify }

enum ControlRefreshReason { acknowledged, conflict }

/// A connection revision, not just a provider ID. Replace [authorityToken] when
/// credentials, endpoint, profile, or the selected connection map changes.
@immutable
class ControlScope {
  const ControlScope(
      {required this.sourceId,
      required this.runId,
      required this.authorityToken});
  final String sourceId;
  final String runId;
  final Object authorityToken;
  bool matches(ControlScope other) =>
      sourceId == other.sourceId &&
      runId == other.runId &&
      identical(authorityToken, other.authorityToken);
}

/// Parent adapter contract: all callbacks MUST use the same authenticated
/// origin/profile/run and reject redirects and obsolete connection revisions.
/// supportsAction(approval) requires advertised run_approval_response AND a
/// verified run_approval endpoint. Clarify requires a verified canonical Hermes
/// route/version (discovery currently omits it), never an invented capability.
/// Neither callback may create a chat turn or use the WebSocket reply DTO.
class ControlBoundary {
  const ControlBoundary(
      {required this.scope,
      required this.refresh,
      required this.postDecision,
      required this.isCurrentAuthority,
      required this.supportsAction,
      this.onReconciled});
  final ControlScope scope;
  final Future<PendingControlsSnapshot> Function() refresh;
  final Future<ControlPostResult> Function(
      ControlAction action, Map<String, Object?> exactBody) postDecision;
  final bool Function(ControlScope scope) isCurrentAuthority;
  final bool Function(ControlAction action) supportsAction;
  final void Function(
          PendingControlsSnapshot snapshot, ControlRefreshReason reason)?
      onReconciled;
}

class ControlPostResult {
  const ControlPostResult(this.statusCode, this.body);
  final int statusCode;
  final Map<String, Object?> body;
}

@immutable
class PendingControl {
  PendingControl._(
      this.action,
      this.promptId,
      this.generation,
      this.description,
      this.command,
      this.question,
      List<String> choices,
      this.canApprove)
      : choices = List.unmodifiable(choices);
  final ControlAction action;
  final String promptId;
  final int generation;
  final String? description;
  final String? command;
  final String? question;
  final List<String> choices;
  final bool canApprove;
  String get revision => jsonEncode([
        action.name,
        promptId,
        generation,
        description,
        command,
        question,
        choices,
        canApprove
      ]);
  bool accepts(String value) => action == ControlAction.approval
      ? (value == 'deny' || (value == 'once' && canApprove)) &&
          choices.contains(value)
      : value.trim().isNotEmpty &&
          value.length <= 4000 &&
          (choices.isEmpty || choices.contains(value));
}

@immutable
class PendingControlsSnapshot {
  PendingControlsSnapshot._(this.scope, this.generation,
      List<PendingControl> controls, this.hasMalformedControls)
      : controls = List.unmodifiable(controls);
  final ControlScope scope;
  final int generation;
  final List<PendingControl> controls;
  final bool hasMalformedControls;
  factory PendingControlsSnapshot.fromJson(
      ControlScope scope, Map<String, Object?> json) {
    if (json['run_id'] != scope.runId ||
        json['execution_generation'] is! int ||
        (json['execution_generation'] as int) < 0 ||
        json['pending_controls'] is! List) {
      throw const FormatException('Invalid pending controls snapshot');
    }
    final generation = json['execution_generation'] as int;
    final controls = <PendingControl>[];
    var malformed = false;
    for (final raw in json['pending_controls'] as List) {
      if (raw is! Map ||
          raw['prompt_id'] is! String ||
          (raw['prompt_id'] as String).trim().isEmpty ||
          raw['execution_generation'] != generation ||
          raw['execution_generation'] is! int ||
          !['approval', 'clarify'].contains(raw['kind']) ||
          raw['choices'] is! List ||
          (raw['choices'] as List)
              .any((v) => v is! String || v.isEmpty || v.length > 500)) {
        malformed = true;
        continue;
      }
      final choices = (raw['choices'] as List).cast<String>();
      if (choices.length > 32 ||
          choices.toSet().length != choices.length ||
          raw['multi_select'] == true) {
        malformed = true;
        continue;
      }
      String? text(String key, int limit) {
        final v = raw[key];
        return v is String && v.trim().isNotEmpty && v.length <= limit
            ? v
            : null;
      }

      final action = raw['kind'] == 'approval'
          ? ControlAction.approval
          : ControlAction.clarify;
      final command = text('command', 2000);
      final question = text('question', 2000);
      if (action == ControlAction.clarify && question == null) {
        malformed = true;
        continue;
      }
      controls.add(PendingControl._(
          action,
          raw['prompt_id'] as String,
          generation,
          text('description', 1000),
          command,
          question,
          choices,
          command != null && !RegExp(r'^\s*[\[{]').hasMatch(command)));
    }
    // Duplicate prompt identities cannot safely identify a single waiter.
    if (controls.map((c) => c.promptId).toSet().length != controls.length) {
      malformed = true;
      controls.clear();
    }
    if ([
      'completed',
      'complete',
      'failed',
      'cancelled',
      'interrupted',
      'resolved'
    ].contains(json['status'])) {
      controls.clear();
    }
    return PendingControlsSnapshot._(scope, generation, controls, malformed);
  }
}

/// No polling, credentials, or transport ownership. Parent supplies snapshots via
/// refresh() and disposes this controller on source/run changes.
class AgentControlsController extends ChangeNotifier {
  AgentControlsController(this.boundary, {this.redact, this.onDispose});
  final String Function(String)? redact;
  final VoidCallback? onDispose;
  final ControlBoundary boundary;
  PendingControlsSnapshot? snapshot;
  String? message;
  bool busy = false;
  bool _disposed = false;
  bool _revoked = false;
  bool get isCurrent =>
      !_disposed && !_revoked && boundary.isCurrentAuthority(boundary.scope);

  void updateSnapshot(PendingControlsSnapshot fresh) {
    if (!isCurrent || !fresh.scope.matches(boundary.scope)) return;
    snapshot = fresh;
    if (!busy) notifyListeners();
  }

  void revoke() {
    if (_revoked) return;
    _revoked = true;
    onDispose?.call();
    Future.microtask(() {
      if (!_disposed) notifyListeners();
    });
  }

  bool canDecide(PendingControl prompt, String value) =>
      isCurrent &&
      !busy &&
      boundary.supportsAction(prompt.action) &&
      prompt.accepts(value);

  Future<PendingControlsSnapshot?> _read() async {
    if (!isCurrent) return null;
    final fresh = await boundary.refresh();
    if (!isCurrent) return null;
    if (!fresh.scope.matches(boundary.scope)) {
      throw const FormatException('Source changed');
    }
    snapshot = fresh;
    return fresh;
  }

  Future<void> refresh() async {
    if (busy || !isCurrent) return;
    busy = true;
    notifyListeners();
    try {
      await _read();
      message = snapshot?.hasMalformedControls == true
          ? 'Some requests cannot be shown safely.'
          : null;
    } catch (_) {
      if (isCurrent) {
        snapshot = null;
        message = 'Could not refresh requests. Try again.';
      }
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> decide(PendingControl prompt, String value) async {
    if (!canDecide(prompt, value)) return;
    busy = true;
    message = null;
    notifyListeners();
    try {
      final fresh = await _read();
      if (!isCurrent || fresh == null) return;
      final matches =
          fresh.controls.where((p) => p.revision == prompt.revision);
      if (matches.length != 1 || !matches.single.accepts(value)) {
        message =
            'This request changed or is no longer pending. Review the current request.';
        return;
      }
      if (!boundary.supportsAction(prompt.action)) {
        message = 'Responding is not supported by this connection.';
        return;
      }
      final result = await boundary.postDecision(
          prompt.action,
          Map.unmodifiable({
            'request_id': prompt.promptId,
            'execution_generation': prompt.generation,
            if (prompt.action == ControlAction.approval)
              'choice': value
            else
              'answer': value,
          }));
      if (!isCurrent) return;
      ControlRefreshReason? reason;
      if (result.statusCode == 409) {
        reason = ControlRefreshReason.conflict;
        message =
            'This request changed or was answered elsewhere. Status refreshed.';
      } else if (result.statusCode >= 200 &&
          result.statusCode < 300 &&
          result.body['run_id'] == boundary.scope.runId &&
          result.body['prompt_id'] == prompt.promptId &&
          result.body['status'] == 'resolved') {
        reason = ControlRefreshReason.acknowledged;
        message =
            'Response acknowledged; this is not completion of the action.';
      } else {
        message =
            'Response was not confirmed. Check the current status before trying again.';
      }
      final updated = await _read();
      if (isCurrent && updated != null && reason != null) {
        boundary.onReconciled?.call(updated, reason);
      }
    } catch (_) {
      if (isCurrent) {
        message =
            'Could not confirm the response. Refresh before trying again.';
      }
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    revoke();
    _disposed = true;
    super.dispose();
  }
}
