/// Canonical-session lifecycle, separate from HTTP Runs. Never retries inference.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../storage/saathi_store.dart';
import 'hermes_gateway.dart';
import 'session_creation.dart';

class CanonicalQueuedInput {
  const CanonicalQueuedInput(this.id, this.text);
  final String id, text;
  Map<String, String> toJson() => {'id': id, 'text': text};
}

/// Same-store, per-session handoff barrier. Accepted reservations drain before
/// a replacement reads recovery evidence; revocation rejects new work only.
class _CanonicalAuthority {
  Future<void>? _tail;
  CanonicalChat? owner;
  String? profile;
  bool blocked = false;
  List<CanonicalQueuedInput> queued = [];
  Map<String, dynamic>? journal;

  Future<T> run<T>(Future<T> Function() action) {
    final before = _tail;
    final result = before == null ? action() : before.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

final _authorities = Expando<Map<String, _CanonicalAuthority>>();

class CanonicalChat extends ChangeNotifier {
  CanonicalChat(this.client, this.secrets,
      {required this.source, required this.isCurrent}) {
    creation = GatewaySessionCreation(client, secrets,
        source: source, isCurrent: () => connected);
    _events = client.events.listen(_event);
    _states = client.states.listen((_) {
      if (!_closed) notifyListeners();
    });
  }
  final HermesGatewayClient client;
  final SecretStore secrets;
  final String source;
  final bool Function() isCurrent;
  late final GatewaySessionCreation creation;
  late final StreamSubscription<GatewayEvent> _events;
  late final StreamSubscription<GatewayConnectionState> _states;
  bool _closed = false, _suspended = false, _refreshing = false;
  bool _inputRevoked = false;
  bool _journalMutation = false;
  bool _sending = false, _attaching = false;
  int _epoch = 0;
  Map<String, dynamic>? _journal;
  GatewaySnapshot? snapshot;
  String? streamText, _problem;
  bool _previewTruncated = false;
  String? get problem => _previewTruncated
      ? 'Live preview limit reached. Further preview text is omitted; resync for the authoritative result.${_problem == null ? '' : '\n$_problem'}'
      : _problem;
  set problem(String? value) => _problem = value;
  bool pending = false;
  bool awaitingSnapshotSave = false;
  String? get heldInput =>
      _journal?['state'] == 'prepared' ? _journal!['text'] as String? : null;
  String? get heldInputId =>
      heldInput == null ? null : _journal!['inputId'] as String?;
  String? get pendingInputId =>
      pending ? (_journal?['inputId'] as String?) : null;
  List<CanonicalQueuedInput> _queued = [];
  List<CanonicalQueuedInput> get queuedInputs => List.unmodifiable(_queued);
  bool queueDirty = false;
  _CanonicalAuthority _authority(String session) =>
      (_authorities[secrets] ??= {}).putIfAbsent(
          'gateway.journal.$source.$session', _CanonicalAuthority.new);
  bool _owns(_CanonicalAuthority authority) =>
      identical(authority.owner, this) &&
      authority.profile == client.profileId &&
      !authority.blocked;
  String _queueKey(String profile, String session) =>
      'gateway.fifo.v1.${base64Url.encode(utf8.encode(jsonEncode([
            source,
            profile,
            session
          ])))}';

  Future<void> _changeQueue(
      List<CanonicalQueuedInput> Function(List<CanonicalQueuedInput>) change,
      {String? cancellationId}) {
    if (!connected || snapshot == null) {
      throw StateError('Original FIFO authority revoked');
    }
    final profile = client.profileId!;
    final session = snapshot!.sessionId;
    final authority = _authority(session);
    if (!_owns(authority)) throw StateError('Original FIFO owner changed');
    // Plan inside the reservation, against the last committed state.
    return authority.run(() => _changeQueueNow(
        change, authority, profile, session,
        cancellationId: cancellationId));
  }

  Future<void> _changeQueueNow(
      List<CanonicalQueuedInput> Function(List<CanonicalQueuedInput>) change,
      _CanonicalAuthority authority,
      String profile,
      String session,
      {String? cancellationId}) async {
    if (!_owns(authority)) throw StateError('Original FIFO owner changed');
    final discardJournal = authority.journal?['inputId'] == cancellationId &&
            cancellationId != null
        ? authority.journal
        : null;
    if (discardJournal != null && discardJournal['state'] != 'prepared') {
      throw StateError('Input outcome is unproven');
    }
    final key = _queueKey(profile, session);
    final prior = await secrets.read(key);
    final candidate = change(authority.queued);
    final encoded = jsonEncode([for (final item in candidate) item.toJson()]);
    if (candidate.length > 1000 || encoded.length > 2 * 1024 * 1024) {
      throw StateError('Saved queue limit reached');
    }
    try {
      await secrets.write(key, encoded);
      if (discardJournal != null &&
          !await _deleteJournal(
              authority, 'gateway.journal.$source.$session', discardJournal)) {
        throw StateError('Original held journal identity changed');
      }
    } catch (_) {
      queueDirty = true;
      try {
        if (await secrets.read(key) != prior) {
          if (prior == null) {
            await secrets.delete(key);
          } else {
            await secrets.write(key, prior);
          }
        }
      } catch (_) {
        // Unknown backing state cannot authorize another destructive snapshot.
        authority.blocked = true;
      }
      rethrow;
    }
    authority.queued = candidate;
    if (discardJournal != null) authority.journal = null;
    if (discardJournal != null && identical(_journal, discardJournal)) {
      _journal = null;
    }
    if (snapshot?.sessionId == session) {
      _queued = candidate;
      queueDirty = false;
    }
  }

  /// Durable accepted next-turn input. Persistence is separate from submission.
  Future<void> queueInput(String id, String text) {
    if (!connected ||
        id.isEmpty ||
        id.length > 256 ||
        text.isEmpty ||
        text.length > 256 * 1024) {
      throw StateError('Input cannot be queued');
    }
    return _changeQueue((before) => before.any((item) => item.id == id)
        ? before
        : [...before, CanonicalQueuedInput(id, text)]);
  }

  Future<void> retryQueueSave() => _changeQueue((before) => before);

  /// Cancel only proven-not-dispatched input. The FIFO and any prepared journal
  /// form one transition: commit neither in-memory removal until both succeed.
  Future<void> removeQueuedInput(String id) {
    if (pendingInputId == id) throw StateError('Input outcome is unproven');
    return _changeQueue(
        (before) => before.where((item) => item.id != id).toList(),
        cancellationId: id);
  }

  VoidCallback? onResyncRequired;
  bool get connected =>
      observable &&
      !_inputRevoked &&
      !_attaching &&
      (snapshot == null || _owns(_authority(snapshot!.sessionId)));
  bool get observable =>
      !_closed &&
      !_suspended &&
      client.state == GatewayConnectionState.connected &&
      isCurrent();
  List<GatewayMessage> get messages => snapshot?.messages ?? const [];
  bool get needsUserAction => snapshot?.needsUserAction ?? false;
  String get _key => 'gateway.journal.$source.${snapshot!.sessionId}';
  bool _valid(int epoch) =>
      !_closed && !_suspended && epoch == _epoch && isCurrent();
  Future<void> connect() async {
    if (_closed || !isCurrent()) throw StateError('Source revoked');
    _suspended = false;
    final epoch = ++_epoch;
    await client.connect();
    if (!_valid(epoch)) {
      await client.disconnect();
      throw StateError('Source revoked');
    }
  }

  Future<List<GatewaySession>> sessions() async {
    if (!connected) throw StateError('Connect first');
    final epoch = _epoch;
    final live = await client.listSessions(limit: 200);
    if (!_valid(epoch)) throw StateError('Source revoked');
    final stored = await client.listSessions(stored: true, limit: 200);
    if (!_valid(epoch)) throw StateError('Source revoked');
    // Official stored scope excludes canonical sessions already in live scope.
    return {
      for (final row in [...live, ...stored]) row.id: row
    }.values.toList();
  }

  Future<void> attach(String id) async {
    if (!connected || _journalMutation) throw StateError('Connect first');
    // Attachment is an authority transition, even if its I/O later fails.
    final epoch = ++_epoch;
    _attaching = true;
    try {
      final value = await client.attach(id);
      if (!_valid(epoch)) throw StateError('Source revoked');
      final key = 'gateway.journal.$source.${value.sessionId}';
      final authority = _authority(value.sessionId);
      await authority.run(() async {
        if (!_valid(epoch) || authority.blocked) {
          throw StateError('Original session authority unavailable');
        }
        final saved = await secrets.read(key);
        if (!_valid(epoch)) throw StateError('Source revoked');
        final journal = saved == null
            ? null
            : Map<String, dynamic>.from(jsonDecode(saved) as Map);
        if (journal != null &&
            (journal['profileId'] != client.profileId ||
                journal['sessionId'] != value.sessionId)) {
          suspend();
          throw const GatewayException(
              'Journal belongs to a different Hermes authority');
        }
        final encodedQueue =
            await secrets.read(_queueKey(client.profileId!, value.sessionId));
        if (!_valid(epoch)) throw StateError('Source revoked');
        final decodedQueue =
            encodedQueue == null ? <dynamic>[] : jsonDecode(encodedQueue);
        if (encodedQueue != null && encodedQueue.length > 2 * 1024 * 1024 ||
            decodedQueue is! List ||
            decodedQueue.length > 1000) {
          throw const FormatException('Invalid saved native FIFO');
        }
        final queued = <CanonicalQueuedInput>[];
        final ids = <String>{};
        for (final row in decodedQueue) {
          if (row is! Map ||
              row['id'] is! String ||
              row['text'] is! String ||
              (row['id'] as String).isEmpty ||
              (row['id'] as String).length > 256 ||
              (row['text'] as String).isEmpty ||
              (row['text'] as String).length > 256 * 1024 ||
              !ids.add(row['id'] as String)) {
            throw const FormatException('Invalid saved native FIFO item');
          }
          queued.add(
              CanonicalQueuedInput(row['id'] as String, row['text'] as String));
        }
        snapshot = value;
        authority.owner = this;
        authority.profile = client.profileId;
        authority.queued = queued;
        authority.journal = journal;
        _queued = queued;
        queueDirty = false;
        _journal = journal;
        pending = journal != null && journal['state'] != 'prepared';
        if (pending) {
          problem =
              'Previous input needs reconciliation. It will not be sent again.';
        }
        notifyListeners();
      });
    } finally {
      if (epoch == _epoch) _attaching = false;
    }
  }

  Future<bool> decide(GatewayRequest prompt, String answer) async {
    if (!connected ||
        controlBusy ||
        _refreshing ||
        !(snapshot?.requests.contains(prompt) ?? false)) {
      return false;
    }
    final epoch = _epoch;
    controlBusy = true;
    notifyListeners();
    try {
      if (!_valid(epoch)) return false;
      final accepted = await client.decide(prompt, answer);
      if (!_valid(epoch)) return false;
      if (accepted) onResyncRequired?.call();
      return accepted;
    } catch (_) {
      if (_valid(epoch)) {
        problem = 'Decision outcome unconfirmed. Resync before deciding again.';
      }
      return false;
    } finally {
      controlBusy = false;
      if (!_closed) notifyListeners();
    }
  }

  bool controlBusy = false;
  bool get canControl =>
      connected &&
      !controlBusy &&
      !needsUserAction &&
      !_refreshing &&
      client.run?.state == GatewayRunState.running &&
      client.run?.executionGeneration != null;

  /// Busy-time native control, never a next-turn submission or completion.
  Future<bool> control(String action, {String? text}) async {
    if (!canControl) return false;
    final epoch = _epoch;
    final generation = client.run!.executionGeneration!;
    controlBusy = true;
    notifyListeners();
    try {
      // A synchronous listener may revoke the source before the network call.
      if (!_valid(epoch)) return false;
      final accepted =
          await client.control(action, generation: generation, text: text);
      if (!_valid(epoch)) return false;
      problem = accepted
          ? (action == 'interrupt'
              ? 'Stop requested. Waiting for Hermes to confirm the outcome.'
              : 'Guidance accepted for current work; not a new turn.')
          : 'Control was not confirmed. Keep your draft and check the session.';
      return accepted;
    } catch (_) {
      if (_valid(epoch)) {
        problem =
            'Control outcome unconfirmed. Do not repeat it automatically.';
      }
      return false;
    } finally {
      controlBusy = false;
      if (!_closed) notifyListeners();
    }
  }

  /// Delete only the exact proven-not-dispatched journal, before removing its UI
  /// queue item. A failed secure delete leaves the original held item intact.
  Future<bool> discardHeldInput(String inputId) async {
    if (!connected ||
        snapshot == null ||
        _journalMutation ||
        heldInputId != inputId) {
      return false;
    }
    final authority = _authority(snapshot!.sessionId);
    if (!_owns(authority)) return false;
    final journal = _journal!;
    final key = _key;
    _journalMutation = true;
    try {
      return await authority.run(() async {
        if (!await _deleteJournal(authority, key, journal)) return false;
        authority.journal = null;
        if (identical(_journal, journal)) _journal = null;
        if (!_closed) notifyListeners();
        return true;
      });
    } finally {
      _journalMutation = false;
    }
  }

  // Called only inside the same reservation as owner handoff and journal writes.
  // An input ID alone is not authority over a newer admission or state.
  Future<bool> _deleteJournal(_CanonicalAuthority authority, String key,
      Map<String, dynamic> expected) async {
    if (!_owns(authority)) return false;
    final raw = await secrets.read(key);
    if (raw == null) return false;
    final stored = jsonDecode(raw);
    if (stored is! Map ||
        !['inputId', 'profileId', 'sessionId', 'admissionId', 'state']
            .every((field) => stored[field] == expected[field])) {
      return false;
    }
    try {
      await secrets.delete(key);
    } catch (_) {
      try {
        await secrets.write(key, raw);
      } catch (_) {
        authority.blocked = true;
      }
      rethrow;
    }
    return true;
  }

  Future<void> send(String text, {String? inputId}) async {
    if (!connected || snapshot == null) throw StateError('Source revoked');
    final epoch = _epoch;
    final authority = _authority(snapshot!.sessionId);
    if (!_owns(authority)) throw StateError('Original session owner changed');
    return authority.run(() {
      if (!_valid(epoch) || !_owns(authority)) {
        throw StateError('Source revoked');
      }
      return _send(text, inputId: inputId);
    });
  }

  Future<void> _send(String text, {String? inputId}) async {
    if (!connected ||
        _sending ||
        _attaching ||
        _journalMutation ||
        snapshot == null ||
        pending ||
        _refreshing ||
        awaitingSnapshotSave ||
        needsUserAction ||
        snapshot!.running) {
      throw StateError(
          'Attach an idle session and reconcile previous work first');
    }
    final epoch = _epoch;
    final sessionId = snapshot!.sessionId;
    final profileId = client.profileId;
    final journalKey = _key;
    final id = inputId ??
        List.generate(
            24,
            (_) => Random.secure()
                .nextInt(256)
                .toRadixString(16)
                .padLeft(2, '0')).join();
    final journal = <String, dynamic>{
      'inputId': id,
      'text': text,
      'sessionId': sessionId,
      'profileId': profileId,
      'state': 'prepared',
    };
    bool valid() =>
        _valid(epoch) &&
        !_attaching &&
        identical(_journal, journal) &&
        snapshot?.sessionId == sessionId &&
        client.attached?.sessionId == sessionId &&
        client.profileId == profileId;
    Future<void> cancelBeforeDispatch() async {
      if (!await _deleteJournal(_authority(sessionId), journalKey, journal)) {
        throw StateError('Original journal identity changed');
      }
      _authority(sessionId).journal = null;
      if (identical(_journal, journal)) {
        _journal = null;
        pending = false;
      }
      throw StateError('Source revoked before dispatch');
    }

    _sending = true;
    _journal = journal;
    _authority(sessionId).journal = journal;
    pending = true;
    streamText = null;
    _previewTruncated = false;
    problem = null;
    try {
      try {
        await secrets.write(journalKey, jsonEncode(journal));
      } catch (_) {
        if (identical(_journal, journal)) {
          _authority(sessionId).journal = null;
          _journal = null;
          pending = false;
        }
        rethrow;
      }
      if (!valid()) await cancelBeforeDispatch();
      // The exact captured record/target, never a later attachment's journal.
      journal['state'] = 'uncertain';
      await secrets.write(journalKey, jsonEncode(journal));
      if (!valid()) await cancelBeforeDispatch();
      try {
        final run = await client.submit(text,
            inputId: id,
            expectedSessionId: sessionId,
            expectedProfileId: profileId);
        if (!valid()) return;
        journal.addAll({'admissionId': run.admissionId, 'state': 'admitted'});
        await secrets.write(journalKey, jsonEncode(journal));
        if (!valid()) return;
      } catch (_) {
        if (valid()) {
          problem =
              'Outcome unconfirmed. Check the original session; do not resend.';
        }
        rethrow;
      }
    } finally {
      _sending = false;
      if (!_closed) notifyListeners();
    }
  }

  /// Reads only: receipt then original-session snapshot. A terminal ACK alone
  /// never releases followers; ChatController must durably save this snapshot.
  Future<bool> refresh() {
    if (!observable || snapshot == null) return Future.value(false);
    final epoch = _epoch;
    final authority = _authority(snapshot!.sessionId);
    if (!_owns(authority)) return Future.value(false);
    return authority.run(() async {
      if (!_valid(epoch) || !_owns(authority)) return false;
      return _refresh();
    });
  }

  Future<bool> _refresh() async {
    if (!observable || _attaching || snapshot == null || _refreshing) {
      return false;
    }
    _refreshing = true;
    final epoch = _epoch;
    try {
      // Read the authoritative pending table before attempting receipt recovery.
      // Matching text is never ownership: require exact input and original ref.
      final value = await client.attach(snapshot!.sessionId);
      if (!_valid(epoch)) return false;
      snapshot = value;
      if (_journal != null && pending) {
        var admission = _journal!['admissionId'] as String?;
        if (admission == null) {
          final matches = value.pendingInputs
              .where((row) =>
                  row['input_id'] == _journal!['inputId'] &&
                  row['ref'] is Map &&
                  row['ref']['session_id'] == _journal!['sessionId'] &&
                  row['ref']['profile_id'] == client.profileId &&
                  row['admission_id'] is String)
              .toList();
          if (matches.length == 1) {
            admission = matches.single['admission_id'] as String;
            _journal!['admissionId'] = admission;
            await secrets.write(_key, jsonEncode(_journal));
            if (!_valid(epoch)) return false;
          }
        }
        if (admission == null) {
          final landed = value.messages.any((row) =>
              row.role == 'user' && row.submissionId == _journal!['inputId']);
          problem = landed
              ? 'This input landed in the original session. Its terminal outcome is unproven. Nothing will be resent.'
              : 'Admission ACK was lost. Ownership is unproven. Nothing will be resent.';
        } else {
          final run = await client.recoverRun(
              admissionId: admission, inputId: _journal!['inputId'] as String);
          if (!_valid(epoch)) return false;
          if ([
            GatewayRunState.complete,
            GatewayRunState.failed,
            GatewayRunState.cancelled
          ].contains(run.state)) {
            _journal!['state'] = 'terminal';
            await secrets.write(_key, jsonEncode(_journal));
            if (!_valid(epoch)) return false;
            // Receipt can settle after the initial snapshot was read.
            snapshot = await client.attach(value.sessionId);
            if (!_valid(epoch)) return false;
          } else if (run.state == GatewayRunState.unknown) {
            final landed = value.messages.any((row) =>
                row.role == 'user' && row.submissionId == _journal!['inputId']);
            problem = landed
                ? 'This input landed in the original session. Its terminal outcome is unproven. Nothing will be resent.'
                : 'Admission is known, but its terminal outcome is unproven. Nothing will be resent.';
          }
        }
      }
      if (_journal == null || _journal?['state'] == 'terminal') {
        streamText = null;
        _previewTruncated = false;
      }
      awaitingSnapshotSave = true;
      notifyListeners();
      return _journal == null ||
          _journal!['state'] == 'terminal' ||
          heldInput != null;
    } finally {
      _refreshing = false;
    }
  }

  Future<void> markSnapshotSaved() {
    if (!observable || snapshot == null) return Future.value();
    final epoch = _epoch;
    final authority = _authority(snapshot!.sessionId);
    if (!_owns(authority)) return Future.value();
    return authority.run(() async {
      if (!_valid(epoch) || !_owns(authority)) return;
      await _markSnapshotSaved(authority);
    });
  }

  Future<void> _markSnapshotSaved(_CanonicalAuthority authority) async {
    final journal = _journal;
    final epoch = _epoch;
    if (journal != null &&
        journal['state'] != 'terminal' &&
        heldInput == null) {
      return;
    }
    if (journal?['state'] == 'terminal') {
      final key = _key;
      // Remove a durable queued head before releasing its no-replay journal.
      await _changeQueueNow(
          (before) =>
              before.where((item) => item.id != journal!['inputId']).toList(),
          authority,
          client.profileId!,
          snapshot!.sessionId);
      if (!_valid(epoch) || !identical(_journal, journal)) return;
      if (!await _deleteJournal(authority, key, journal!)) return;
      authority.journal = null;
      if (!_valid(epoch) || !identical(_journal, journal)) return;
      _journal = null;
      pending = false;
    }
    awaitingSnapshotSave = false;
    problem = null;
    if (!_closed) notifyListeners();
  }

  void _event(GatewayEvent event) {
    if (!observable || event.sessionId != snapshot?.sessionId) return;
    if (event.type == 'message.delta') {
      if (!_previewTruncated) {
        final previous = streamText ?? '';
        if (event.text.length > 256 * 1024 - previous.length) {
          _previewTruncated = true;
        } else {
          streamText = '$previous${event.text}';
        }
      }
    } else if (event.type == 'message.complete') {
      onResyncRequired?.call();
    } else if (event.type == 'approval.request' ||
        event.type == 'clarify.request') {
      problem = 'Hermes needs your decision. Resyncing the current request.';
      onResyncRequired?.call();
    } else if (event.type == 'session.replay_gap') {
      problem = 'History changed. Resync before sending.';
      onResyncRequired?.call();
    }
    notifyListeners();
  }

  /// Selection revokes input forever, while the captured source may still be
  /// observed read-only to save its completion into its own conversation.
  void revokeInput() {
    _inputRevoked = true;
    ++_epoch;
    problem = 'Input disconnected. Import a fresh host invite before sending.';
  }

  /// Revoke synchronously; background/resume cannot revive an old secure read.
  void suspend() {
    _suspended = true;
    ++_epoch;
    problem = 'Disconnected. Import a fresh host invite to reconnect.';
    unawaited(client.disconnect());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    suspend();
    await _events.cancel();
    await _states.cancel();
    await client.dispose();
    super.dispose();
  }
}
