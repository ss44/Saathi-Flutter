import 'dart:async';
import 'dart:convert';

import '../chat_organization/organization.dart';
import '../chat_organization/organization_widgets.dart';
import '../chat_organization/reported_usage.dart';
import '../gateway/canonical_chat.dart';
import '../gateway/hermes_gateway.dart';
import '../gateway/host_invite.dart';
import '../agent_runs/run_client.dart';
import '../agent_runs/run_history_sync.dart';
import 'transcript_presentation.dart';
import '../agent_controls/agent_controls.dart';

import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/saathi_core.dart';
import '../notifications/reply_notifications.dart';
import '../storage/saathi_store.dart';

class ChatSession {
  final String id, connectionId, model, systemPrompt;
  final String? upstreamProvider;
  final String? remoteSessionId, remoteTitle;
  final String? canonicalProfileId;
  final List<ChatMessage> messages;
  ChatSession({
    required this.id,
    required this.connectionId,
    required this.model,
    this.upstreamProvider,
    this.remoteSessionId,
    this.remoteTitle,
    this.canonicalProfileId,
    this.systemPrompt = '',
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];
  String get title =>
      remoteTitle ??
      (messages.isEmpty
          ? 'New conversation'
          : messages.first.content.isEmpty && messages.first.photos.isNotEmpty
              ? 'Photo message'
              : messages.first.content);
  DateTime? get latestMessageAt {
    DateTime? latestVisible;
    for (final message in messages) {
      if (!showsHistoryBubble(message)) continue;
      final ts = message.timestamp;
      if (ts != null && (latestVisible == null || ts.isAfter(latestVisible))) {
        latestVisible = ts;
      }
    }
    if (latestVisible != null) return latestVisible;
    DateTime? latestAny;
    for (final message in messages) {
      final ts = message.timestamp;
      if (ts != null && (latestAny == null || ts.isAfter(latestAny))) {
        latestAny = ts;
      }
    }
    return latestAny;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'connectionId': connectionId,
        'model': model,
        if (upstreamProvider != null) 'upstreamProvider': upstreamProvider,
        if (remoteSessionId != null) 'remoteSessionId': remoteSessionId,
        if (remoteTitle != null) 'remoteTitle': remoteTitle,
        if (canonicalProfileId != null)
          'canonicalProfileId': canonicalProfileId,
        'systemPrompt': systemPrompt,
        'messages': messages.map((m) => m.toJson()).toList(),
      };
  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'],
        connectionId: json['connectionId'],
        model: json['model'],
        upstreamProvider: json['upstreamProvider'] as String?,
        remoteSessionId: json['remoteSessionId'] as String?,
        remoteTitle: json['remoteTitle'] as String?,
        canonicalProfileId: json['canonicalProfileId'] as String?,
        systemPrompt: json['systemPrompt'] ?? '',
        messages: (json['messages'] as List)
            .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
}

typedef CoreFactory = SaathiCore Function();

enum _DispatchResult {
  completed,
  admitted,
  stopped,
  dispatchedUnknown,
  notDispatched,
}

class _DispatchPermission {
  final QueuedFollowup source;
  bool revoked = false;
  _DispatchPermission(this.source);
}

class QueuedFollowup {
  final String text;
  final List<ChatPhoto> photos;
  final ChatSession session;
  final Map<String, dynamic> connection;
  final CapturedInstructions captured;
  final String replyId;
  final String model;
  QueuedFollowup(
    this.text,
    this.session,
    this.connection, {
    CapturedInstructions? captured,
    List<ChatPhoto> photos = const [],
    String? replyId,
    String? model,
  })  : photos = List.unmodifiable(photos),
        model = model ?? session.model,
        captured =
            captured ?? CapturedInstructions(null, 0, session.systemPrompt),
        replyId = replyId ?? 'reply-${runIdentity()}';

  Map<String, dynamic> preparedJson(String state) => {
        'chatId': session.id,
        'connectionId': session.connectionId,
        'connectionRevision': connection['authorityEpoch'],
        'connectionType': connection['type'],
        'connectionUrl': connection['url'],
        'model': model,
        'upstreamProvider': session.upstreamProvider,
        'text': text,
        'replyId': replyId,
        'state': state,
        'personaId': captured.personaId,
        'personaRevision': captured.revision,
        'instructions': captured.instructions,
      };
}

/// Local identity plus original server authority; never use a bare run ID as
/// cross-server identity. The opaque revision is not a connection/key map.
class ScopedRunSnapshot {
  ScopedRunSnapshot({
    required this.localChatId,
    required this.connectionId,
    required this.connectionRevision,
    required this.operationKey,
    required Map<String, String?> originalAuthority,
    required this.snapshot,
    required bool Function() isCurrent,
    bool Function()? isObservable,
    this.eventsSupported = false,
    this.originalConnection,
  })  : originalAuthority = Map.unmodifiable(originalAuthority),
        _isCurrent = isCurrent,
        _isObservable = isObservable ?? isCurrent;
  final bool eventsSupported;
  final Map<String, dynamic>? originalConnection;
  final String localChatId, connectionId, operationKey;
  final Object connectionRevision;
  final Map<String, String?> originalAuthority;
  final RunSnapshot snapshot;
  final bool Function() _isCurrent;
  final bool Function() _isObservable;
  bool isCurrent() => _isCurrent();
  bool isObservable() => _isObservable();
}

/// Safe client-side explanation; never includes a raw backend error body.
class RemoteContinuationUnavailable extends StateError {
  RemoteContinuationUnavailable(super.message);
}

class ChatController extends ChangeNotifier {
  late final ChatOrganization organization;
  ChatSession? _dispatchingSession;
  bool _recordingOrganization = false;
  final _completionBacklog = <(ConversationIdentity, String)>{};
  final _capacityBacklog = <(ConversationIdentity, String)>{};
  final _seenBacklog = <(ConversationIdentity, String)>{};
  final _preparedInputs = <String, Map<String, dynamic>>{};
  final _quarantinedInputs = <ChatSession>{};
  static const preparedInputsKey = 'saathi.prepared-inputs.v1';
  static const maxInputLength = 256 * 1024;
  static const maxStreamPreviewLength = 256 * 1024;
  static const _stopQueueNotice =
      'Stopped work pauses the queue. Review the result before choosing Resume.';

  ConversationIdentity identityOf(ChatSession session) =>
      ConversationIdentity(session.connectionId, session.id);
  String displayTitle(ChatSession session) =>
      organization.entry(identityOf(session)).title(session.title);
  bool get organizationBlocked =>
      !organization.loaded ||
      organization.saving ||
      organization.hasUnsavedChanges ||
      _completionBacklog.isNotEmpty ||
      _capacityBacklog
          .any((item) => current != null && item.$1 == identityOf(current!));
  String? get organizationProblem => _capacityBacklog
          .any((item) => current != null && item.$1 == identityOf(current!))
      ? 'This conversation reached its saved reply-details limit. Its answer is retained and will not be resent. Other conversations remain available.'
      : organization.error;

  PersonaEditPolicy personaPolicy(ConversationIdentity identity) {
    final session =
        sessions.where((s) => identityOf(s) == identity).firstOrNull;
    final connection =
        connections.where((c) => c['id'] == identity.connectionId).firstOrNull;
    if (session == null || connection == null) {
      return PersonaEditPolicy.importedReadOnly;
    }
    return session.remoteSessionId != null ||
            runs.containsKey(session.id) ||
            !['openai', 'anthropic', 'gemini'].contains(connection['type'])
        ? PersonaEditPolicy.serverOwned
        : PersonaEditPolicy.localInstructions;
  }

  String? pendingPersonaReason(ConversationIdentity identity) {
    final session =
        sessions.where((s) => identityOf(s) == identity).firstOrNull;
    if (session == null) return 'The original conversation is unavailable.';
    if (personaPolicy(identity) != PersonaEditPolicy.localInstructions) {
      return 'This server does not support changing the persona of an existing conversation.';
    }
    if (_uncertain.containsKey(session)) {
      return 'Resolve the uncertain request before changing its persona.';
    }
    if (identical(_dispatchingSession, session) ||
        identical(_preparing?.source.session, session) ||
        _outbox.any((item) => identical(item.session, session)) ||
        (runs[session.id] != null && !runs[session.id]!.committed)) {
      return 'Wait for accepted and queued work before changing this persona.';
    }
    return null;
  }

  /// The native adapter never consumes app-local model overrides.
  String replyModel(ChatSession session) =>
      personaPolicy(identityOf(session)) == PersonaEditPolicy.localInstructions
          ? organization.entry(identityOf(session)).replyModel ?? session.model
          : session.model;

  String? chatSettingsRestriction(ChatSession session) {
    if (_disposed || _loadFailed || loading || !sessions.contains(session)) {
      return 'The original conversation is unavailable.';
    }
    if (personaPolicy(identityOf(session)) !=
        PersonaEditPolicy.localInstructions) {
      return 'This connection has no verified contract for changing an existing server conversation’s model, persona or system instructions. Server values are not available here. Nothing will be changed on the server.';
    }
    if (changingConnection || unsavedChanges) {
      return 'Finish connection changes or recover unsaved replies first.';
    }
    if (_preparedInputs.containsKey(session.id)) {
      return 'Resolve accepted or uncertain input before changing chat settings.';
    }
    return pendingPersonaReason(identityOf(session));
  }

  /// Save only future direct replies and optional local display name. Existing
  /// work and connection ownership are immutable; native session mutation
  /// requires a separate verified adapter API.
  Future<void> saveChatSettings(
    ChatSession session, {
    required Map<String, dynamic>? originalConnection,
    required int selection,
    required String model,
    required String instructions,
    required String? personaId,
    String? displayName,
  }) async {
    if (selection != selectionGeneration || !identical(current, session)) {
      throw StateError('The conversation changed. Reopen chat settings.');
    }
    await organization.saveChatSettings(
      identityOf(session),
      replyModel: model,
      instructions: instructions,
      personaId: personaId,
      displayName: displayName,
      restriction: () {
        // Once Save is accepted, recovery belongs to this original conversation,
        // not whichever chat is selected when the user retries its storage write.
        if (originalConnection == null ||
            !isCurrentConnection(originalConnection)) {
          return 'The original connection changed. Recover its settings before sending.';
        }
        return chatSettingsRestriction(session);
      },
    );
  }

  /// Save a local display name for [session] without modifying model, persona,
  /// instructions, or server configuration.
  Future<void> renameConversation(
    ChatSession session, {
    required Map<String, dynamic>? originalConnection,
    required int selection,
    required String displayName,
  }) async {
    if (selection != selectionGeneration || !identical(current, session)) {
      throw StateError('The conversation changed. Reopen chat settings.');
    }
    await organization.renameConversation(
      identityOf(session),
      displayName,
      restriction: () {
        if (_disposed ||
            _loadFailed ||
            loading ||
            !sessions.contains(session)) {
          return 'The original conversation is unavailable.';
        }
        if (originalConnection != null &&
            !isCurrentConnection(originalConnection)) {
          return 'The original connection changed. Recover its settings before sending.';
        }
        if (changingConnection || unsavedChanges) {
          return 'Finish connection changes or recover unsaved replies first.';
        }
        return null;
      },
    );
  }

  ConversationWorkState workState(ChatSession session) {
    final native = identical(session, _canonicalSession) ? _canonical : null;
    if (native != null) {
      if (native.needsUserAction) return ConversationWorkState.awaitingInput;
      if (native.pending ||
          native.awaitingSnapshotSave ||
          (native.snapshot?.running ?? false)) {
        return native.client.run == null
            ? ConversationWorkState.unknown
            : ConversationWorkState.working;
      }
    }
    final op = runs[session.id];
    if (op != null) {
      final state = op.snapshot.state;
      if (state == RunState.unknown || state == RunState.unrecognized) {
        return ConversationWorkState.unknown;
      }
      if (state == RunState.failed) return ConversationWorkState.failed;
      if (state == RunState.cancelled || state == RunState.interrupted) {
        return ConversationWorkState.cancelled;
      }
      if (!op.committed && !op.snapshot.terminal) {
        if (state == RunState.waitingForApproval ||
            op.snapshot.pendingControls.isNotEmpty) {
          return ConversationWorkState.awaitingInput;
        }
        return state == RunState.queued
            ? ConversationWorkState.queued
            : ConversationWorkState.working;
      }
    }
    if (_uncertain.containsKey(session)) return ConversationWorkState.unknown;
    if (identical(_dispatchingSession, session)) {
      return ConversationWorkState.working;
    }
    if (_outbox.any((item) => identical(item.session, session))) {
      return ConversationWorkState.queued;
    }
    return ConversationWorkState.idle;
  }

  void _organizationChanged() {
    notifyListeners();
    if (!_disposed &&
        !_recordingOrganization &&
        organization.loaded &&
        !organization.saving &&
        !organization.hasUnsavedChanges &&
        (_completionBacklog.isNotEmpty || _seenBacklog.isNotEmpty)) {
      scheduleMicrotask(_flushOrganization);
    }
  }

  Future<void> _flushOrganization() async {
    if (_disposed ||
        _recordingOrganization ||
        !organization.loaded ||
        organization.saving ||
        organization.hasUnsavedChanges) {
      return;
    }
    _recordingOrganization = true;
    try {
      while (_completionBacklog.isNotEmpty) {
        final item = _completionBacklog.first;
        try {
          await organization.recordCompletion(item.$1, item.$2);
          _capacityBacklog.remove(item);
        } on OrganizationCapacityException catch (e) {
          if (e.identity != item.$1) rethrow;
          // Capacity is not a failed storage transaction. Keep exact evidence
          // for this chat without stranding unrelated conversations behind it.
          _capacityBacklog.add(item);
        }
        _completionBacklog.remove(item);
      }
      while (_seenBacklog.isNotEmpty) {
        final item = _seenBacklog.first;
        // A visibility observation is never an admission or completion record.
        if (organization.entry(item.$1).completions.containsKey(item.$2)) {
          await organization.markReplyVisible(item.$1, item.$2);
        }
        _seenBacklog.remove(item);
      }
    } catch (_) {
      // Keep the authoritative answer and exact identity; retry storage only.
      organization.error ??=
          'Reply details could not be saved. The answer is retained; retry saving details without sending again.';
    } finally {
      _recordingOrganization = false;
      _scheduleSelectedQueue();
      notifyListeners();
    }
  }

  Future<void> replyVisible(ChatSession session, String replyId) async {
    final identity = identityOf(session);
    if (organization.entry(identity).completions[replyId] != false) return;
    _seenBacklog.add((identity, replyId));
    await _flushOrganization();
    if (organization.entry(identity).completions[replyId] != true) {
      throw StateError('Reply visibility is not yet durably saved');
    }
  }

  Future<void> retryOrganizationSave() async {
    try {
      await organization.retrySave();
      _completionBacklog.addAll(_capacityBacklog);
      await _flushOrganization();
    } catch (_) {
      /* The original metadata candidate remains visible. */
    }
  }

  /// One authoritative answer path for ordinary and attachment responses.
  /// Retains its original identity and never repeats inference on a save failure.
  Future<void> _completeReply(
    ChatSession session, {
    required String input,
    required String text,
    required String replyId,
    Map<String, dynamic> metadata = const {},
  }) async {
    if (text.trim().isEmpty) {
      _terminalProblems[session] = _emptyFinalMessage;
    } else {
      _terminalProblems.remove(session);
    }
    final now = DateTime.now().toUtc().toIso8601String();
    session.messages.addAll([
      ChatMessage(
        role: 'user',
        content: input,
        metadata: {'timestamp': now},
      ),
      ChatMessage(
        role: 'model',
        content: text,
        id: replyId,
        metadata: {
          ...ReportedUsage.fromMetadata(metadata).toMetadata(),
          'timestamp':
              parseMessageTimestamp(metadata['timestamp'])?.toIso8601String() ??
                  now,
          if (text.trim().isNotEmpty) 'authoritativeCompletion': true,
        },
      ),
    ]);
    if (text.trim().isNotEmpty) await _recordCompletion(session, replyId);
    try {
      if (!_disposed && text.trim().isNotEmpty) {
        onReplyReceived?.call(session.id);
      }
    } catch (_) {
      // Optional notification cannot turn an accepted answer into a resend.
    }
    try {
      await persist();
      await _clearSavedPrepared();
    } catch (_) {
      unsavedChanges = true;
      pauseQueue(
        'Queue paused until the response is saved. Then choose Resume.',
        allSources: true,
      );
      error =
          'Response received but not saved. Keep this conversation open and try saving again before closing Saathi.';
    }
  }

  Future<void> _recordCompletion(ChatSession session, String replyId) async {
    if (_capacityBacklog.contains((identityOf(session), replyId))) return;
    _completionBacklog.add((identityOf(session), replyId));
    await _flushOrganization();
  }

  Future<void> _restorePrepared() async {
    final raw = store.preferences.getString(preparedInputsKey);
    if (raw == null) return;
    if (raw.length > 2 * 1024 * 1024) {
      throw const FormatException('Prepared inputs too large');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.length > 1000) {
      throw const FormatException('Invalid prepared inputs');
    }
    var changed = false;
    for (final row in decoded) {
      if (row is! Map ||
          [
            'chatId',
            'connectionId',
            'replyId',
            'text',
            'instructions',
            'state',
          ].any((key) => row[key] is! String) ||
          (row['instructions'] as String).length > 16000 ||
          (row['text'] as String).length > 256 * 1024 ||
          (row['replyId'] as String).isEmpty ||
          (row['replyId'] as String).length > 256 ||
          row['personaRevision'] is! int ||
          (row['personaRevision'] as int) < 0 ||
          (row['quarantined'] != null && row['quarantined'] is! bool) ||
          (row['personaId'] != null &&
              (row['personaId'] is! String ||
                  (row['personaId'] as String).length > 256)) ||
          !['prepared', 'dispatched'].contains(row['state'])) {
        throw const FormatException('Invalid prepared input');
      }
      var session = sessions
          .where(
            (s) =>
                s.id == row['chatId'] && s.connectionId == row['connectionId'],
          )
          .firstOrNull;
      final missingSession = session == null;
      // Retain orphaned recovery evidence under its original identity. It is
      // never a new conversation or permission to replay the retained input.
      if (session == null) {
        session = ChatSession(
          id: row['chatId'] as String,
          connectionId: row['connectionId'] as String,
          model: row['model'] is String ? row['model'] as String : '',
          upstreamProvider: row['upstreamProvider'] as String?,
          remoteTitle: 'Held recovery input',
        );
        sessions.add(session);
      }
      final connection =
          connections.where((c) => c['id'] == row['connectionId']).firstOrNull;
      if (_preparedInputs.containsKey(session.id)) {
        throw const FormatException('Duplicate prepared input');
      }
      final quarantined = row['quarantined'] == true ||
          missingSession ||
          connection == null ||
          row['connectionRevision'] != connection['authorityEpoch'] ||
          row['connectionType'] != connection['type'] ||
          row['connectionUrl'] != connection['url'] ||
          row['model'] != replyModel(session) ||
          row['upstreamProvider'] != session.upstreamProvider;
      final item = QueuedFollowup(
        row['text'] as String,
        session,
        quarantined
            ? <String, dynamic>{
                'id': row['connectionId'],
                'authorityEpoch': row['connectionRevision'],
                'type': row['connectionType'],
                'url': row['connectionUrl'],
              }
            : connection,
        model: row['model'] as String,
        replyId: row['replyId'] as String,
        captured: CapturedInstructions(
          row['personaId'] as String?,
          row['personaRevision'] as int,
          row['instructions'] as String,
        ),
      );
      _preparedInputs[session.id] = Map<String, dynamic>.from(row);
      if (session.messages.any((m) => m.id == item.replyId)) continue;
      if (quarantined) {
        changed = changed || row['quarantined'] != true;
        _preparedInputs[session.id]!['quarantined'] = true;
        _quarantinedInputs.add(session);
        _uncertain[session] = item;
        _paused[session] =
            'Original conversation or connection changed. This recovery input is held separately and will never be resent. Review it before explicitly discarding it.';
      } else if (row['state'] == 'prepared') {
        _outbox.add(item);
        _paused[session] =
            'Prepared input restored without sending. Review it, then choose Resume.';
      } else {
        _uncertain[session] = item;
        _paused[session] =
            'Outcome unknown after restart. This input will not be sent again.';
      }
    }
    // Persist revocation before a recovered orphan can appear in any later chat
    // snapshot. Recreating its local row must never restore send authority.
    if (changed) await _changePrepared((_) {});
  }

  Future<void>? _preparedTail;
  Future<void> _changePrepared(
    void Function(Map<String, Map<String, dynamic>>) change,
  ) {
    Future<void> write() async {
      final next = {..._preparedInputs};
      change(next);
      final encoded = jsonEncode(next.values.toList());
      if (encoded.length > 2 * 1024 * 1024 || next.length > 1000) {
        throw StateError('Prepared input storage limit reached');
      }
      final before = store.preferences.getString(preparedInputsKey);
      try {
        if (!await store.preferences.setString(preparedInputsKey, encoded)) {
          throw StateError('Could not save the prepared input');
        }
      } catch (_) {
        // The legacy preferences API mutates its cache before the platform
        // acknowledges durability. Restore the exact prior record even when
        // the compensating platform write also fails; recreation shares cache.
        try {
          if (before == null) {
            await store.preferences.remove(preparedInputsKey);
          } else {
            await store.preferences.setString(preparedInputsKey, before);
          }
        } catch (_) {
          // Runtime journal and held/uncertain barriers remain unchanged.
        }
        rethrow;
      }
      _preparedInputs
        ..clear()
        ..addAll(next);
    }

    final before = _preparedTail;
    final operation = before == null ? write() : before.then((_) => write());
    _preparedTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _savePrepared(QueuedFollowup item, String state) =>
      _changePrepared(
        (next) => next[item.session.id] = item.preparedJson(state),
      );

  Future<void> _clearSavedPrepared() => _changePrepared((next) {
        next.removeWhere(
          (id, row) => sessions.any(
            (session) =>
                session.id == id &&
                session.messages.any((m) => m.id == row['replyId']),
          ),
        );
      });

  Future<bool> _discardPrepared(QueuedFollowup item) async {
    if (_preparedInputs[item.session.id]?['replyId'] != item.replyId) {
      return true;
    }
    try {
      await _changePrepared((next) => next.remove(item.session.id));
      return true;
    } catch (_) {
      error =
          'The held input could not be removed from storage. Try this action again; nothing was sent.';
      notifyListeners();
      return false;
    }
  }

  final List<QueuedFollowup> _outbox = [];
  List<QueuedFollowup> get outbox => List.unmodifiable(
        _outbox.where((item) => identical(item.session, current)),
      );
  final Map<ChatSession, QueuedFollowup> _uncertain = {};
  final Map<ChatSession, String> _paused = {};
  final Map<ChatSession, String> _recoveryPauses = {};
  final Map<ChatSession, String> _foregroundPauses = {};
  final Set<QueuedFollowup> _foregroundHeld = {};
  QueuedFollowup? get uncertainInput => _uncertain[current];
  String? get queueStatus => uncertainInput != null || outbox.isNotEmpty
      ? _paused[current] ??
          _recoveryPauses[current] ??
          (unsavedChanges ? 'Waiting to save your reply.' : null)
      : null;
  bool _draining = false, _background = false;
  int _catalogGeneration = 0;
  bool _catalogPaused = false;

  /// Background/disposal revokes discovery permanently, even after resume.
  int get catalogGeneration => _catalogGeneration;
  bool get canDiscoverModels =>
      !_disposed && !_background && !_catalogPaused && !changingConnection;

  _DispatchPermission? _preparing;

  bool _bound(QueuedFollowup item) =>
      identical(current, item.session) &&
      sessions.contains(item.session) &&
      connections.any((c) => identical(c, item.connection)) &&
      item.connection['id'] == item.session.connectionId;

  final _verifiedRunPhotos = Expando<Object>();

  bool _supportsPhotos(Map<String, dynamic> connection) =>
      connection['type'] == 'hermes' &&
      _verifiedRunPhotos[connection] != null &&
      identical(_verifiedRunPhotos[connection], _controlRevisions[connection]);

  /// Whether the composer can offer to check Hermes API photo support.
  bool get canPickPhotos =>
      !readOnly &&
      !changingConnection &&
      _selectedConnection?['type'] == 'hermes';

  /// Photo submission requires a verified Hermes Runs connection.
  bool get canAttachPhotos =>
      canPickPhotos && _supportsPhotos(_selectedConnection!);

  /// Verify the current Hermes HTTP connection before opening a device picker.
  /// This sends only capability discovery and binds the result to selection and
  /// credential revision.
  Future<bool> verifyPhotoInput() async {
    if (!canPickPhotos) return false;
    final connection = _selectedConnection!;
    final selection = selectionGeneration;
    final generation = _runsGeneration;
    final revision = _controlRevisions[connection] ??= Object();
    bool current() =>
        !_disposed &&
        !_background &&
        !_runsPaused &&
        !changingConnection &&
        selection == selectionGeneration &&
        generation == _runsGeneration &&
        identical(revision, _controlRevisions[connection]) &&
        isCurrentConnection(connection);
    RunClient? client;
    try {
      client = await _runClient(connection, isCurrent: current);
      await client.discover();
      if (!current()) return false;
      _verifiedRunPhotos[connection] = client.photosSupported ? revision : null;
      return client.photosSupported;
    } catch (_) {
      if (current()) _verifiedRunPhotos[connection] = null;
      return false;
    } finally {
      client?.close();
    }
  }

  /// Accepts a text or photo draft into the original conversation's send queue.
  /// A false return leaves the entire draft with the caller.
  bool submit(String text, {List<ChatPhoto> photos = const []}) {
    final session = current;
    if (!_validInput(text, session)) return false;
    if (_disposed ||
        loading ||
        readOnly ||
        changingConnection ||
        unsavedChanges ||
        organizationBlocked ||
        queueStatus != null ||
        uncertainInput != null ||
        _background ||
        session == null ||
        (text.trim().isEmpty && photos.isEmpty)) {
      return false;
    }
    final connection = connections.singleWhere(
      (c) => c['id'] == session.connectionId,
    );
    if (photos.isNotEmpty &&
        (!_supportsPhotos(connection) || !ChatPhoto.fitsDraft(photos))) {
      error =
          'These photos cannot be sent with the current model or exceed the attachment limit.';
      notifyListeners();
      return false;
    }
    _outbox.add(
      QueuedFollowup(
        text,
        session,
        connection,
        model: replyModel(session),
        photos: photos,
        captured: organization.captureInstructions(
          identityOf(session),
          fallback: session.systemPrompt,
        ),
      ),
    );
    if (connection['type'] == 'hermesGateway') {
      final owner = canonical;
      final item = _outbox.last;
      if (owner == null || !owner.connected) {
        _outbox.remove(item);
        return false;
      }
      _saveCanonicalQueue(item, owner);
    } else {
      unawaited(_drainOutbox());
    }
    notifyListeners();
    return true;
  }

  final _canonicalQueueWrites = <ChatSession, Future<void>>{};
  Future<void> Function()? _canonicalQueueSaveRetry;
  bool get canonicalQueueSaving => _canonicalQueueSaving.contains(current);
  void _saveCanonicalQueue(QueuedFollowup item, CanonicalChat owner) {
    final session = item.session;
    _canonicalHeldOwners[item] = owner;
    _canonicalQueueSaving.add(session);
    // Future.sync also captures a synchronous adapter admission rejection.
    final write =
        Future<void>.sync(() => owner.queueInput(item.replyId, item.text));
    _canonicalQueueWrites[session] = write;
    unawaited(() async {
      try {
        await write;
      } catch (_) {
        _paused[session] =
            'Input is held until its queue is saved. Try saving again, then choose Resume.';
        unsavedChanges = true;
        _canonicalQueueSaveRetry = () async {
          for (final held
              in _outbox.where((held) => identical(held.session, session))) {
            if (!owner.queuedInputs.any((saved) => saved.id == held.replyId)) {
              await owner.queueInput(held.replyId, held.text);
            }
          }
          await owner.retryQueueSave();
        };
        if (identical(current, session)) error = _paused[session];
      } finally {
        if (identical(_canonicalQueueWrites[session], write)) {
          unawaited(_canonicalQueueWrites.remove(session));
          _canonicalQueueSaving.remove(session);
          if (!_disposed) {
            _scheduleSelectedQueue();
            notifyListeners();
          }
        }
      }
    }());
  }

  Future<void> cancelQueued(QueuedFollowup item) async {
    if (!_outbox.contains(item) ||
        _canonicalQueueSaving.contains(item.session)) {
      return;
    }
    final owner = _canonicalHeldOwners[item];
    if (owner != null) {
      {
        _canonicalQueueSaving.add(item.session);
        notifyListeners();
        try {
          await owner.removeQueuedInput(item.replyId);
        } catch (_) {
          _paused[item.session] =
              'Could not remove saved held input. Try canceling again.';
          if (identical(current, item.session)) error = _paused[item.session];
          return;
        } finally {
          _canonicalQueueSaving.remove(item.session);
          scheduleMicrotask(() {
            if (!_disposed) notifyListeners();
          });
        }
      }
      _canonicalHeldOwners.remove(item);
    }
    if (_preparedInputs[item.session.id]?['replyId'] == item.replyId &&
        !await _discardPrepared(item)) {
      return;
    }
    _outbox.remove(item);
    if (!_outbox.any((i) => identical(i.session, item.session)) &&
        !_uncertain.containsKey(item.session)) {
      _paused.remove(item.session);
    }
    notifyListeners();
  }

  // Call only after acknowledgment of the unknown server outcome.
  Future<void> abandonHeldOutbox(ChatSession session) async {
    if (_disposed || !_uncertain.containsKey(session)) return;
    if (!await _discardPrepared(_uncertain[session]!)) return;
    _outbox.removeWhere((item) => identical(item.session, session));
    _uncertain.remove(session);
    _quarantinedInputs.remove(session);
    _paused.remove(session);
    notifyListeners();
  }

  void pauseQueue(
    String reason, {
    ChatSession? session,
    bool allSources = false,
  }) {
    final source = session ?? current;

    _foregroundPauses
        .removeWhere((chat, _) => allSources || identical(chat, source));
    _foregroundHeld
        .removeWhere((item) => allSources || identical(item.session, source));
    final preparing = _preparing;
    if (preparing != null &&
        (allSources || identical(preparing.source.session, source))) {
      preparing.revoked = true;
      _paused[preparing.source.session] = reason;
    }
    for (final item in _outbox) {
      if (allSources || identical(item.session, source)) {
        _paused[item.session] = reason;
      }
    }
    notifyListeners();
  }

  void setQueueBackground(bool background) {
    if (_background == background) return;
    _background = background;
    if (background) {
      _catalogGeneration++;
      final previous = Map<ChatSession, String>.of(_paused);
      final preparing = _preparing?.source;
      pauseQueue(
        'Messages are held while Saathi is in the background.',
        allSources: true,
      );
      _paused.addAll(previous);
      for (final entry in _paused.entries) {
        if (!previous.containsKey(entry.key)) {
          _foregroundPauses[entry.key] = entry.value;
        }
      }
      if (preparing != null && !previous.containsKey(preparing.session)) {
        _foregroundHeld.add(preparing);
      }
    } else {
      final session = current;
      if (session != null &&
          _paused[session] == _foregroundPauses[session] &&
          _foregroundPauses.containsKey(session) &&
          !readOnly &&
          !_uncertain.containsKey(session) &&
          _outbox
              .where((item) => identical(item.session, session))
              .every(_bound)) {
        _paused.remove(session);
        _foregroundPauses.remove(session);
      }
      _scheduleSelectedQueue();
      notifyListeners();
    }
  }

  bool get canResumeQueue =>
      !_disposed &&
      !_background &&
      !busy &&
      !runPending &&
      !loading &&
      !readOnly &&
      !changingConnection &&
      !unsavedChanges &&
      !organizationBlocked &&
      !_canonicalQueueSaving.contains(current) &&
      uncertainInput == null &&
      outbox.isNotEmpty &&
      outbox.every(_bound);

  void resumeQueue() {
    if (!canResumeQueue) return;
    _paused.remove(current);
    unawaited(_drainOutbox());
  }

  void _scheduleSelectedQueue() {
    if (!_draining &&
        !busy &&
        !runPending &&
        !_disposed &&
        !_background &&
        !loading &&
        !readOnly &&
        !changingConnection &&
        !unsavedChanges &&
        !organizationBlocked &&
        !canonicalQueueSaving &&
        queueStatus == null &&
        uncertainInput == null &&
        outbox.isNotEmpty &&
        outbox.every(_bound)) {
      scheduleMicrotask(_drainOutbox);
    }
  }

  Future<void> _drainOutbox() async {
    if (_draining || busy || runPending || _disposed || canonicalQueueSaving) {
      return;
    }
    _draining = true;
    try {
      while (outbox.isNotEmpty && !_disposed) {
        if (busy || runPending || canonicalQueueSaving) break;
        if (queueStatus != null || uncertainInput != null) break;
        if (_background ||
            loading ||
            readOnly ||
            changingConnection ||
            unsavedChanges ||
            organizationBlocked ||
            !_bound(outbox.first)) {
          pauseQueue(
            'Queue paused. Restore the original conversation and connection, and save before resuming.',
          );
          break;
        }
        final item = outbox.first;
        _outbox.remove(item);
        final result = await _dispatch(item.text, source: item);
        if (result == _DispatchResult.notDispatched) {
          _outbox.insert(0, item);
          if (_foregroundHeld.remove(item) &&
              !_background &&
              _bound(item) &&
              !_paused.containsKey(item.session) &&
              !unsavedChanges &&
              !organizationBlocked) {
            break; // Fresh dispatch permission, same accepted unsent input.
          }
          _paused.putIfAbsent(
            item.session,
            () => 'Not sent. Queue held. Choose Resume when ready.',
          );
          break;
        }
        _canonicalHeldOwners.remove(item);
        _foregroundHeld.remove(item);
        if (result == _DispatchResult.stopped) {
          if (!_uncertain.containsKey(item.session) &&
              !unsavedChanges &&
              _outbox
                  .any((queued) => identical(queued.session, item.session))) {
            _paused[item.session] = _stopQueueNotice;
          }
          break;
        }
        if (result == _DispatchResult.dispatchedUnknown) {
          _uncertain[item.session] = item;
          _paused[item.session] =
              'Outcome unknown. The last request may have executed. It will not be sent again. Start a new conversation safely, or explicitly abandon this held outbox.';
          break;
        }
        if (result == _DispatchResult.admitted) break;
        if (unsavedChanges) {
          pauseQueue(
            'Queue paused until the response is saved. Then choose Resume.',
            allSources: true,
          );
          break;
        }
      }
    } finally {
      _draining = false;
      _paused.removeWhere(
        (session, _) =>
            !_uncertain.containsKey(session) &&
            !_outbox.any((item) => identical(item.session, session)),
      );
      _scheduleSelectedQueue();
      notifyListeners();
    }
  }

  final SaathiStore store;
  final CoreFactory coreFactory;
  void Function(String sessionId)? onReplyReceived;
  ReplyNotifications? notifications;
  final List<Map<String, dynamic>> connections = [];
  final List<ChatSession> sessions = [];
  ChatSession? _current;
  int _selectionGeneration = 0;

  /// Selection authority is revoked on the first change, even after A→B→A.
  int get selectionGeneration => _selectionGeneration;
  ChatSession? get current => _current;
  set current(ChatSession? session) {
    if (!identical(_current, session)) {
      // Activity navigation and restoration can set selection directly. None
      // may bypass the native owner's irreversible input/control revocation.
      if (_canonicalSession != null && identical(_current, _canonicalSession)) {
        _canonical?.revokeInput();
      }
      _selectionGeneration++;
    }
    _current = session;
  }

  bool loading = true, busy = false, unsavedChanges = false;
  bool _disposed = false;
  bool _loadFailed = false;
  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final directCancel = _directCancel;
    if (directCancel != null && !directCancel.isCompleted) {
      directCancel.complete();
    }
    _directCancel = null;
    _directStreamSession = null;
    _directStreamPreview = null;
    _directStoppedByUser = false;
    unawaited(_canonical?.close());
    _poll?.cancel();
    _runUpdates.close();
    _scopedRunUpdates.close();
    organization.removeListener(_organizationChanged);
    organization.dispose();
    onReplyReceived = null;
    super.dispose();
  }

  static const _emptyFinalMessage =
      'The server finished without a text response. Nothing will be resent.';
  // A terminal outcome belongs to its conversation, not a storage attempt.
  // Transient failures take precedence without erasing the retained outcome.
  final _terminalProblems = <ChatSession, String>{};
  String? _error, _pendingText;
  String? get error => _error ?? _terminalProblems[current];
  set error(String? value) => _error = value;
  String? get pendingText {
    if (canonical?.pendingText != null) return canonical!.pendingText;
    final op = currentRun;
    if (op != null &&
        !current!.messages.any((m) => m.id == 'input-${op.key}')) {
      return op.input;
    }
    return identical(current, _dispatchingSession) ? _pendingText : null;
  }

  set pendingText(String? value) => _pendingText = value;

  /// Photos for the currently selected conversation's in-flight input only.
  List<ChatPhoto> get pendingPhotos {
    final op = currentRun;
    if (op != null &&
        !current!.messages.any((m) => m.id == 'input-${op.key}')) {
      return op.photos;
    }
    return identical(current, _dispatchingSession)
        ? _preparing?.source.photos ?? const []
        : const [];
  }

  final RunClientFactory? runClientFactory;
  final bool _runDiscovery;

  /// Android HTTP Runs uses admission plus bounded foreground status reads.
  /// This does not change the distinct native hermesGateway WSS contract.
  bool get usesRunStatusSync =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final Map<String, RunOperation> runs = {};
  final _streamText = <String, String>{};
  final _streamCursors = <String, BigInt>{};
  final _observationProblems = <String, String>{};
  final _statusFailures = <String, int>{};
  final _syncReceived = <String>{};
  final _reportedActivity = <String, String>{};
  RunOperation? _dispatchRun;
  Completer<void>? _directCancel;
  ChatSession? _directStreamSession;
  String? _directStreamPreview;
  bool _directStoppedByUser = false;

  bool _needsReceiptSync(RunOperation op) =>
      !op.committed &&
      !op.snapshot.terminal &&
      op.runId == null &&
      op.data['attempted'] == true;

  int _pollLimit(RunOperation op) =>
      _needsReceiptSync(op) && _syncReceived.contains(op.key) ? 6 : 3;

  bool get _directStreaming =>
      busy && _directCancel != null && !_directCancel!.isCompleted;

  /// True while the currently selected conversation has an active, abortable
  /// direct-model HTTP request in flight.
  bool get canStopDirectReply =>
      !_disposed &&
      _directStreaming &&
      identical(_directStreamSession, current);

  /// True when starting a new conversation is safe, including while an
  /// independent direct-model stream is running in another conversation.
  bool get canStartNewSession =>
      !_disposed &&
      !loading &&
      !changingConnection &&
      !_loadFailed &&
      !unsavedChanges &&
      (!busy || _directStreaming);

  /// Aborts the currently selected conversation's in-flight direct-model reply.
  ///
  /// Pauses any queued follow-ups for that conversation for user review and
  /// never auto-resends or mutates unrelated conversations.
  bool stopDirectReply() {
    if (!canStopDirectReply) return false;
    final session = _directStreamSession!;
    _directStoppedByUser = true;
    _paused[session] = _stopQueueNotice;
    pauseQueue(_stopQueueNotice, session: session);
    final cancel = _directCancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    notifyListeners();
    return true;
  }

  bool get _preparingReply =>
      busy && identical(_dispatchingSession, current) && _dispatchRun == null;
  String? get reportedActivity =>
      !_preparingReply && currentRun?.snapshot.terminal == false
          ? _reportedActivity[currentRun?.key]
          : null;
  // A failed observation or answer does not resolve an authoritative decision.
  // Clarification is represented by pending controls on an otherwise running run.
  bool get _awaitingRunDecision {
    final snapshot = currentRun?.snapshot;
    return snapshot != null &&
        !snapshot.terminal &&
        (snapshot.state == RunState.waitingForApproval ||
            snapshot.pendingControls.isNotEmpty);
  }

  bool get showPendingThinking {
    final owner = canonical;
    if (owner != null) {
      if (canonicalQueueSaving && !owner.pending) return true;
      return owner.replyInProgress;
    }
    if (_preparingReply) return true;
    final op = currentRun;
    if (op == null) return busy && identical(_dispatchingSession, current);
    if (op.snapshot.terminal || _awaitingRunDecision) return false;
    if (busy && identical(_dispatchingSession, current)) return true;
    final failures = _statusFailures[op.key] ?? 0;
    final limit = _pollLimit(op);
    return runPending &&
        (op.snapshot.state == RunState.queued ||
            op.snapshot.state == RunState.running ||
            _needsReceiptSync(op) ||
            failures > 0) &&
        failures <= limit;
  }

  bool _canPoll(RunOperation op) {
    if (op.committed || op.snapshot.terminal) return false;
    final failures = _statusFailures[op.key] ?? 0;
    if (failures > _pollLimit(op)) return false;
    if (op.runId != null) {
      return op.snapshot.state != RunState.unknown || failures > 0;
    }
    return op.data['attempted'] == true;
  }

  void _statusUnavailable(ChatSession session, RunOperation op) {
    final failures = (_statusFailures[op.key] ?? 0) + 1;
    _statusFailures[op.key] = failures;
    _observationProblems[op.key] = failures <= 3
        ? 'Reconnecting to check your reply'
        : 'Could not check your reply. Use Check status when the connection is back. Your message will not be sent again.';
    if (failures > 3) {
      _recoveryPauses[session] =
          'Check your reply before resuming queued messages.';
    }
    _schedulePoll();
  }

  void _syncUnavailable(
    ChatSession session,
    RunOperation op, {
    bool receivedOnServer = false,
    bool manual = false,
  }) {
    if (receivedOnServer) {
      final newlyConfirmed = _syncReceived.add(op.key);
      final previous = _statusFailures[op.key] ?? 0;
      final limit = _pollLimit(op);
      final failures =
          newlyConfirmed || (manual && previous > limit) ? 1 : previous + 1;
      _statusFailures[op.key] = failures;
      if (failures <= limit) {
        _observationProblems[op.key] =
            'Message received. Refreshing chat for your reply';
        _recoveryPauses[session] =
            'Syncing your reply before queued messages continue.';
      } else {
        _observationProblems[op.key] =
            'Message received, but the reply is not ready yet. Tap Refresh to sync again; your message will not be sent again.';
        _recoveryPauses[session] =
            'Sync your reply before resuming queued messages.';
      }
    } else {
      final failures = (_statusFailures[op.key] ?? 0) + 1;
      _statusFailures[op.key] = failures;
      if (failures <= _pollLimit(op)) {
        _observationProblems[op.key] = 'Refreshing chat to sync your reply';
        _recoveryPauses[session] =
            'Syncing your reply before queued messages continue.';
      } else {
        _observationProblems[op.key] =
            'Could not sync your reply yet. Tap Refresh to sync again; your message will not be sent again.';
        _recoveryPauses[session] =
            'Sync your reply before resuming queued messages.';
      }
    }
    _schedulePoll();
  }

  String? get runObservationProblem => _observationProblems[currentRun?.key];

  // Only call after a validated original-run status GET, never a control ACK.
  // Recovery belongs to the existing poll owner, not to the UI that read it.
  void _statusObserved(RunOperation op, {required bool Function() isCurrent}) {
    if (!isCurrent()) throw StateError('Stale observation');
    if (op.runId != null && op.snapshot.data.containsKey('pending_controls')) {
      final controls = PendingControlsSnapshot.fromJson(
        ControlScope(
          sourceId: op.localId,
          runId: op.runId!,
          authorityToken: op,
        ),
        op.snapshot.data,
      );
      if (controls.hasMalformedControls) {
        // Retain safely displayable requests (including denial), but do not
        // grant a new observation budget from malformed control details.
        return;
      }
    }
    _statusFailures.remove(op.key);
    _syncReceived.remove(op.key);
    _observationProblems.remove(op.key);
    // This does not grant dispatch authority or remove intentional queue pauses.
    _schedulePoll();
  }

  /// Presentation of observed state, not decorative thinking or hidden reasoning.
  String get pendingStatus => canonical != null
      ? (canonicalQueueSaving && !canonical!.pending
          ? 'Preparing your message'
          : canonical!.pendingStatus)
      : _preparingReply
          ? 'Sending your message'
          : _awaitingRunDecision
              ? 'Your decision is needed'
              : runObservationProblem != null
                  ? ((_statusFailures[currentRun?.key] ?? 0) <=
                              (currentRun == null
                                  ? 3
                                  : _pollLimit(currentRun!)) &&
                          (currentRun?.runId != null ||
                              (currentRun != null &&
                                  _needsReceiptSync(currentRun!)))
                      ? runObservationProblem!
                      : currentRun != null && _needsReceiptSync(currentRun!)
                          ? 'Refresh chat to sync your reply'
                          : 'Check your message’s status')
                  : switch (currentRun?.snapshot.state) {
                      RunState.queued => 'Waiting for its turn',
                      RunState.running => 'Working on your reply',
                      RunState.stopping => 'Waiting for the server to stop',
                      RunState.waitingForApproval => 'Your decision is needed',
                      RunState.failed =>
                        'The server could not finish this reply',
                      RunState.cancelled ||
                      RunState.interrupted =>
                        'This reply was stopped',
                      RunState.completed => 'Reply received',
                      _ => busy && identical(_dispatchingSession, current)
                          ? 'Sending your message'
                          : 'Check your message’s status',
                    };
  String? get streamingText =>
      canonical?.streamText ??
      (runPending
          ? _streamText[currentRun?.key]
          : (identical(current, _directStreamSession)
              ? _directStreamPreview
              : null));

  /// Observations from the existing activity attachment, never a second stream
  /// or inference. Only an authoritative status read can settle the journal.
  void observeRunEvent(
    ScopedRunSnapshot scope,
    Map<String, Object?> event, {
    String? cursor,
  }) {
    if (usesRunStatusSync ||
        !scope.isCurrent() ||
        event['run_id'] != scope.snapshot.runId) {
      return;
    }
    final op = runs[scope.localChatId];
    if (op == null || op.key != scope.operationKey || op.snapshot.terminal) {
      return;
    }
    final sequence = cursor == null ? null : BigInt.tryParse(cursor);
    if (sequence == null ||
        sequence <= (_streamCursors[op.key] ?? BigInt.from(-1))) {
      return;
    }
    _streamCursors[op.key] = sequence;
    final kind = event['event'];
    final tool = event['tool'];
    // Only public lifecycle labels. Never render arguments, results, previews
    // or reasoning payloads as thinking telemetry.
    if (['tool.started', 'tool.completed', 'tool.failed'].contains(kind) &&
        tool is String &&
        RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(tool)) {
      _reportedActivity[op.key] = switch (kind) {
        'tool.started' => 'Using $tool',
        'tool.completed' => 'Finished $tool',
        _ => 'Tool could not finish: $tool',
      };
      notifyListeners();
    }
    if (event['event'] == 'message.delta' && event['delta'] is String) {
      final text = '${_streamText[op.key] ?? ''}${event['delta']}';
      if (text.length <= 256 * 1024) _streamText[op.key] = text;
      notifyListeners();
    }
    if ([
      'run.completed',
      'run.failed',
      'run.cancelled',
      'run.interrupted',
      'approval.request',
      'clarify.request',
    ].contains(event['event'])) {
      unawaited(checkRunStatus(sessionId: scope.localChatId));
    }
  }

  void runStreamDisconnected(ScopedRunSnapshot scope) {
    final op = runs[scope.localChatId];
    if (!scope.isCurrent() ||
        op == null ||
        op.snapshot.terminal ||
        op.committed) {
      return;
    }
    _observationProblems[op.key] =
        'Live updates disconnected. Check status; the server may still be working.';
    notifyListeners();
  }

  final _runUpdates = StreamController<RunSnapshot>.broadcast();

  /// Compatibility stream; new integrations should use scopedRunSnapshots.
  Stream<RunSnapshot> get runSnapshots => _runUpdates.stream;
  final _scopedRunUpdates = StreamController<ScopedRunSnapshot>.broadcast();
  final _connectionRevisions = Expando<Object>();
  // Mutation-start revocation survives rollback to the same connection map.
  final _controlRevisions = Expando<Object>();
  final _activityEvents = Expando<bool>();
  final _nativeSteer = Expando<bool>();
  final _nativeStop = Expando<bool>();
  bool controlBusy = false;
  Map<String, dynamic>? get _selectedConnection =>
      connections.where((c) => c['id'] == current?.connectionId).firstOrNull;
  bool get canGuideRun =>
      !busy &&
      !changingConnection &&
      !controlBusy &&
      currentRun?.runId != null &&
      currentRun?.snapshot.state == RunState.running &&
      _selectedConnection != null &&
      _nativeSteer[_selectedConnection!] == true;
  bool get canStopRun =>
      !busy &&
      !changingConnection &&
      !controlBusy &&
      runPending &&
      currentRun?.runId != null &&
      !currentRun!.snapshot.terminal &&
      _selectedConnection != null &&
      _nativeStop[_selectedConnection!] == true;

  void _rememberRunFeatures(Map<String, dynamic> connection, RunClient client) {
    _activityEvents[connection] = client.eventsSupported;
    _nativeSteer[connection] = client.canSteer;
    _nativeStop[connection] = client.canStop;
  }

  Future<bool> controlRun({String? guidance}) async {
    if (guidance == null ? !canStopRun : !canGuideRun) return false;
    final session = current!,
        op = currentRun!,
        connection = _selectedConnection!;
    final generation = _runsGeneration;
    final revision = _controlRevisions[connection] ??= Object();
    final selection = selectionGeneration;
    bool valid() =>
        generation == _runsGeneration &&
        selection == selectionGeneration &&
        identical(revision, _controlRevisions[connection]) &&
        identical(current, session) &&
        _active(session, connection, op);
    controlBusy = true;
    if (guidance == null) {
      _paused[session] =
          'Stopped work pauses the queue. Review the result before choosing Resume.';
      pauseQueue(_paused[session]!, session: session);
    }
    notifyListeners();
    RunClient? client;
    try {
      client = await _runClient(connection, isCurrent: valid);
      client.bind(op);
      if (!await client.discover() || !valid()) return false;
      _rememberRunFeatures(connection, client);
      await client.status(op, _ledger, isCurrent: valid);
      _statusObserved(op, isCurrent: valid);
      if (op.snapshot.terminal) {
        await _reconcile(session, connection, op);
        return false;
      }
      await client.control(op, guidance: guidance, isCurrent: valid);
      await client.status(op, _ledger, isCurrent: valid);
      _statusObserved(op, isCurrent: valid);
      await _reconcile(session, connection, op);
      if (valid() && !op.snapshot.terminal) {
        error = guidance == null
            ? 'Stop requested. Waiting for the server to confirm the outcome.'
            : 'Guidance accepted for a checkpoint; not a new turn or proof it was read.';
      }
      return valid();
    } catch (_) {
      if (valid()) {
        error =
            'Control outcome unconfirmed. Do not repeat guidance; check status.';
      }
      return false;
    } finally {
      client?.close();
      controlBusy = false;
      _scheduleSelectedQueue();
      notifyListeners();
    }
  }

  Stream<ScopedRunSnapshot> get scopedRunSnapshots => _scopedRunUpdates.stream;
  RunOperation? get currentRun => runs[current?.id];
  bool get runPending =>
      (canonical?.awaitingSnapshotSave ?? false) ||
      (canonical?.pending ?? false) ||
      (canonical?.snapshot?.running ?? false) ||
      (currentRun != null &&
          (!currentRun!.committed || currentRun!.data['journalDirty'] == true));
  bool _runsPaused = false;
  int _runsGeneration = 0;
  Timer? _poll;
  ChatController(
    this.store, {
    CoreFactory? coreFactory,
    this.runClientFactory,
    OrganizationStorage? organizationStorage,
  })  : _runDiscovery = coreFactory == null || runClientFactory != null,
        coreFactory = coreFactory ?? (() => SaathiCore()) {
    organization = ChatOrganization(
      organizationStorage ?? OrganizationStorage(store.preferences),
    );
    organization.addListener(_organizationChanged);
    // Preferences are already open. Hydrate independent metadata immediately,
    // including owners constructed with already-loaded history.
    unawaited(
      organization.load().catchError((Object _) {
        organization.error =
            'Conversation details could not be read. Nothing has been overwritten.';
        notifyListeners();
      }),
    );
  }

  int _canonicalMutationEpoch = 0;
  void _revokeCanonicalMutation() {
    ++_canonicalMutationEpoch;
    _canonical?.suspend();
  }

  CanonicalChat? _canonical;
  ChatSession? _canonicalSession;
  Map<String, dynamic>? _canonicalConnection;
  final Set<String> _restoredCanonicalInputs = {};
  final Map<QueuedFollowup, CanonicalChat> _canonicalHeldOwners = {};
  final Set<ChatSession> _canonicalQueueSaving = {};
  GatewaySnapshot? _savedCanonicalSnapshot;
  bool _savingCanonical = false;
  bool _canonicalResyncRequested = false;
  Future<void> Function()? _canonicalSaveRetry;
  CanonicalChat? get canonical =>
      _canonicalSession != null && identical(current, _canonicalSession)
          ? _canonical
          : null;

  /// Explicit new host invite for every dial; API keys never mint tickets.
  Future<List<GatewaySession>> connectCanonical(
    Map<String, dynamic> connection,
    String invite,
  ) async {
    if (_runsPaused ||
        busy ||
        unsavedChanges ||
        _canonicalQueueSaving.isNotEmpty ||
        !isCurrentConnection(connection)) {
      throw StateError('Connection unavailable');
    }
    final generation = _runsGeneration;
    _revokeCanonicalMutation();
    final mutation = _canonicalMutationEpoch;
    final source = HostInviteVault.trustedSource(connection['url'] as String);
    bool valid() =>
        !_disposed &&
        !_runsPaused &&
        mutation == _canonicalMutationEpoch &&
        generation == _runsGeneration &&
        isCurrentConnection(connection);
    final vault = HostInviteVault(store.secrets);
    await vault.import(connection['id'] as String, invite, trustedUrl: source);
    if (!valid()) throw StateError('Source revoked');
    await _canonical?.close();
    if (!valid()) throw StateError('Source revoked');
    final owner = CanonicalChat(
      HermesGatewayClient(
        grantProvider: () async {
          if (!valid()) throw StateError('Source revoked');
          final grant = await vault.consume(
            connection['id'] as String,
            trustedUrl: source,
          );
          if (!valid()) throw StateError('Source revoked');
          return grant;
        },
      ),
      store.secrets,
      source: connection['id'] as String,
      isCurrent: valid,
    );
    owner.onResyncRequired = () {
      if (!identical(owner, _canonical)) return;
      _canonicalResyncRequested = true;
      unawaited(refreshCanonical());
    };
    _canonical = owner;
    _canonicalConnection = connection;
    _canonicalSession = null;
    _savedCanonicalSnapshot = null;
    owner.addListener(() {
      notifyListeners();
    });
    await owner.connect();
    return owner.sessions();
  }

  Future<void> attachCanonical(
    GatewaySession remote, {
    ChatSession? expectedSession,
    bool Function()? isOwnerCurrent,
  }) async {
    final owner = _canonical;
    final connection = _canonicalConnection;
    final selection = selectionGeneration;
    bool valid() =>
        (isOwnerCurrent?.call() ?? true) &&
        selection == selectionGeneration &&
        identical(owner, _canonical) &&
        connection != null &&
        isCurrentConnection(connection);
    if (owner == null || connection == null || !owner.connected || !valid()) {
      throw StateError('Connect first');
    }
    if (expectedSession != null &&
        (!sessions.contains(expectedSession) ||
            expectedSession.connectionId != connection['id'] ||
            expectedSession.remoteSessionId != remote.id ||
            expectedSession.canonicalProfileId == null ||
            expectedSession.canonicalProfileId != owner.client.profileId)) {
      throw StateError('Original native profile and session required');
    }
    await owner.attach(remote.id);
    if (!owner.connected || !valid()) {
      // Resume changed the transport attachment. Never leave it writable (or
      // observable as the old local chat) after its navigation owner was revoked.
      owner.suspend();
      throw StateError('Source revoked');
    }
    final id = owner.snapshot!.sessionId;
    final session = sessions
            .where(
              (s) =>
                  s.connectionId == connection['id'] &&
                  s.remoteSessionId == id &&
                  s.canonicalProfileId == owner.client.profileId,
            )
            .firstOrNull ??
        ChatSession(
          id: 'canonical_${runIdentity()}',
          connectionId: connection['id'] as String,
          remoteSessionId: id,
          remoteTitle: remote.title,
          canonicalProfileId: owner.client.profileId,
          model: 'Hermes Desktop / CLI',
        );
    if (!sessions.contains(session)) sessions.add(session);
    select(session);
    _canonicalSession = session;
    final queued = [...owner.queuedInputs];
    if (owner.heldInput != null &&
        owner.heldInputId != null &&
        !queued.any((item) => item.id == owner.heldInputId)) {
      queued.insert(
          0, CanonicalQueuedInput(owner.heldInputId!, owner.heldInput!));
    }
    for (final input in queued) {
      if (input.id == owner.pendingInputId) continue;
      final prior = _outbox
          .where((item) =>
              identical(item.session, session) && item.replyId == input.id)
          .firstOrNull;
      if (prior != null) {
        _canonicalHeldOwners[prior] = owner;
        _paused[session] =
            'Restored input is held. Choose Resume after the original work is reconciled.';
        continue;
      }
      if (_restoredCanonicalInputs.add(
          '${connection['id']}:${session.canonicalProfileId}:$id:${input.id}')) {
        final restored =
            QueuedFollowup(input.text, session, connection, replyId: input.id);
        _outbox.add(restored);
        _canonicalHeldOwners[restored] = owner;
        _paused[session] =
            'Restored input is held. Choose Resume after the original work is reconciled.';
      }
    }
    final attachedSelection = selectionGeneration;
    await refreshCanonical();
    // Persistence accepted before dismissal must finish, but cannot restore the
    // old route's navigation/input authority (including selection round trips).
    if (!(isOwnerCurrent?.call() ?? true) ||
        attachedSelection != selectionGeneration ||
        !identical(current, session) ||
        !identical(owner, _canonical) ||
        !isCurrentConnection(connection) ||
        !owner.connected) {
      owner.suspend();
      throw StateError('Attachment owner revoked');
    }
  }

  /// Authoritative original-session resync; no transcript is uploaded to HTTP chat.
  Future<void> refreshCanonical() async {
    final owner = _canonical;
    final session = _canonicalSession;
    if (owner == null || session == null || _savingCanonical) return;
    _savingCanonical = true;
    try {
      final retry = _canonicalSaveRetry;
      if (retry != null) {
        await retry();
        _canonicalSaveRetry = null;
        _scheduleSelectedQueue();
        return;
      }
      _canonicalResyncRequested = false;
      final inputId = owner.pendingInputId;
      final terminal = await owner.refresh();
      if (!owner.observable ||
          !identical(owner, _canonical) ||
          session.canonicalProfileId != owner.client.profileId) {
        return;
      }
      Future<void> settleSnapshot() async {
        if (!terminal) return;
        if ([GatewayRunState.failed, GatewayRunState.cancelled]
            .contains(owner.client.run?.state)) {
          _paused.putIfAbsent(
            session,
            () =>
                owner.problem ??
                'Review the interrupted reply before continuing.',
          );
        }
        await owner.markSnapshotSaved();
      }

      final snapshot = owner.snapshot;
      final emptyOutcome = switch (owner.client.run?.state) {
        GatewayRunState.complete => _emptyFinalMessage,
        GatewayRunState.failed =>
          'The server could not complete this response. Nothing will be resent.',
        GatewayRunState.cancelled =>
          'This response was cancelled. Nothing will be resent.',
        _ => null,
      };
      if (terminal &&
          inputId != null &&
          emptyOutcome != null &&
          snapshot != null) {
        final inputIndex = snapshot.messages.indexWhere(
          (m) => m.role == 'user' && m.submissionId == inputId,
        );
        // Only the settled local input can establish an empty final. Imported
        // blank history and in-progress/tool rows are not completion evidence.
        if (inputIndex >= 0 &&
            !snapshot.messages
                .skip(inputIndex + 1)
                .takeWhile((m) => m.role != 'user')
                .any((m) => m.isCompletedAnswer)) {
          // Retain the receipt's outcome before storage cleanup clears it.
          _terminalProblems[session] = emptyOutcome;
        }
      }
      if (snapshot != null && !identical(snapshot, _savedCanonicalSnapshot)) {
        final previous = {for (final m in session.messages) m.id: m};
        final completed = <String>[];
        final now = DateTime.now().toUtc().toIso8601String();
        session.messages
          ..clear()
          ..addAll([
            for (var i = 0; i < snapshot.messages.length; i++)
              (() {
                final m = snapshot.messages[i];
                final id =
                    'canonical-${snapshot.storedSessionId}-${m.rowId ?? i}';
                // Imported history is not a new reply. Only a newly observed
                // durable assistant row after attachment is completion evidence.
                final fresh = _savedCanonicalSnapshot != null &&
                    m.isCompletedAnswer &&
                    m.rowId != null &&
                    !previous.containsKey(id);
                if (fresh) completed.add(id);
                return ChatMessage(
                  role: m.role == 'user' ? 'user' : 'model',
                  content: m.text,
                  id: id,
                  metadata: {
                    ...?previous[id]?.metadata,
                    if (fresh && previous[id]?.metadata['timestamp'] == null)
                      'timestamp': now,
                    'canonicalRowKind': m.kind.name,
                    if (fresh) 'authoritativeCompletion': true,
                  },
                );
              })(),
          ]);
        _canonicalSaveRetry = () async {
          for (final id in completed) {
            await _recordCompletion(session, id);
          }
          await persist();
          _savedCanonicalSnapshot = snapshot;
          await settleSnapshot();
          error = null;
        };
        await _canonicalSaveRetry!();
        _canonicalSaveRetry = null;
      } else if (terminal) {
        await settleSnapshot();
      }
      _scheduleSelectedQueue();
    } catch (_) {
      if (_canonicalSaveRetry != null) unsavedChanges = true;
      error =
          'Could not resync or save the original Hermes session. No input was resent.';
    } finally {
      _savingCanonical = false;
      notifyListeners();
      if (_canonicalResyncRequested && !_disposed && owner.observable) {
        scheduleMicrotask(() => unawaited(refreshCanonical()));
      }
    }
  }

  RunLedger get _ledger => RunLedger(store.secrets);

  /// Continue an API-owned conversation through native Runs. Desktop/CLI rows
  /// require a canonical gateway grant; never transplant them through REST.
  bool attachingRemote = false;
  Future<void> continueRemote(
    Map<String, dynamic> connection,
    RemoteSession remote, {
    bool Function()? isOwnerCurrent,
  }) async {
    if (busy ||
        unsavedChanges ||
        changingConnection ||
        _loadFailed ||
        attachingRemote ||
        _runsPaused ||
        !isCurrentConnection(connection) ||
        remote.source != 'api_server') {
      throw StateError('This session requires canonical gateway attachment');
    }
    final generation = _runsGeneration;
    final mutation = _canonicalMutationEpoch;
    final selected = current;
    final selection = selectionGeneration;
    final existing = sessions
        .where((s) =>
            s.connectionId == connection['id'] &&
            s.remoteSessionId == remote.id)
        .firstOrNull;
    final before = existing == null ? null : [...existing.messages];
    final wasIdle = existing != null && _canRefreshRemoteHistory(existing);
    bool valid() =>
        !_disposed &&
        !_runsPaused &&
        !unsavedChanges &&
        !_loadFailed &&
        !changingConnection &&
        mutation == _canonicalMutationEpoch &&
        (isOwnerCurrent?.call() ?? true) &&
        identical(current, selected) &&
        selection == selectionGeneration &&
        generation == _runsGeneration &&
        isCurrentConnection(connection);
    attachingRemote = true;
    notifyListeners();
    SaathiCore? core;
    RunClient? client;
    try {
      core = await coreFor(connection);
      if (!valid()) throw StateError('Connection changed');
      client = await _runClient(connection, isCurrent: valid);
      final supported = await client.discover();
      if (!valid()) throw StateError('Connection changed');
      if (!supported) {
        throw RemoteContinuationUnavailable(
            'This server does not advertise safe native Runs continuation. Ask its operator to enable or upgrade Runs support, then try again. Nothing was sent.');
      }
      // Offset advancement uses raw rows, including hidden/tool-only pages.
      // Never present the first page as a complete conversation.
      final rows = <Map<String, dynamic>>[];
      final seen = <Object>{};
      var offset = 0;
      for (var pages = 0;; pages++) {
        if (pages == 256) {
          throw StateError('History exceeds the bounded attachment window');
        }
        final page = await core.loadRemoteHistory(
          connection['id'] as String,
          remote.id,
          offset: offset,
        );
        if (!valid() || page.sessionId != remote.id) {
          throw StateError('Session identity changed');
        }
        final pagination = page.pagination;
        final returned = pagination['returned'] as int? ?? page.messages.length;
        final limit = pagination['limit'] as int? ?? 100;
        if ((pagination['offset'] ?? offset) != offset ||
            returned != page.messages.length ||
            limit <= 0 ||
            limit > 100 ||
            returned > limit) {
          throw StateError('Invalid history pagination');
        }
        for (final row in page.messages) {
          final id = row['id'];
          if (id is! String && id is! int || seen.add(id!)) rows.add(row);
        }
        offset += returned;
        final more = pagination['has_more'];
        if (returned == 0 || (more is bool ? !more : returned < limit)) break;
      }
      if (existing != null) {
        if (!sessions.contains(existing)) {
          throw StateError('Original conversation removed');
        }
        final history = rows.map(projectRemoteHistory).nonNulls.toList();
        // Import only a proven extension of the unchanged, idle transcript.
        // Keep existing objects/IDs and completion metadata; a stale or divergent
        // snapshot cannot erase local answers, accepted input or uncertainty.
        final unchangedIdle = wasIdle &&
            _canRefreshRemoteHistory(existing) &&
            listEquals(before, existing.messages);
        if (wasIdle && !unchangedIdle) {
          throw RemoteContinuationUnavailable(
              'Your local conversation changed while checking the server. No history was replaced and nothing was sent by opening it. Return to the conversation to review pending work, then try connecting again.');
        }
        final exactPrefix = history.length >= existing.messages.length &&
            Iterable<int>.generate(existing.messages.length).every((i) =>
                existing.messages[i].role == history[i].role &&
                existing.messages[i].content == history[i].content);
        if (unchangedIdle && !exactPrefix) {
          throw RemoteContinuationUnavailable(
              'This conversation changed on the server in a way that cannot be safely combined with your saved history. Your local messages have been kept; nothing was sent. Review the changes on the original host, then try connecting again.');
        }
        if (unchangedIdle && history.length > existing.messages.length) {
          existing.messages.addAll(history.skip(existing.messages.length));
          try {
            await persist();
          } catch (_) {
            unsavedChanges = true;
            error =
                'Updated history could not be saved. Try saving again; nothing was sent.';
            rethrow;
          }
        }
        if (!valid()) throw StateError('Session attachment revoked');
        select(existing);
        return;
      }
      final session = ChatSession(
        id: 'remote_${runIdentity()}',
        connectionId: connection['id'] as String,
        remoteSessionId: remote.id,
        remoteTitle: remote.title,
        model: remote.data['model'] as String? ?? 'Server model',
        upstreamProvider: remote.data['provider'] as String?,
        messages: rows.map(projectRemoteHistory).nonNulls.toList(),
      );
      sessions.add(session);
      try {
        await persist();
      } catch (_) {
        sessions.remove(session);
        rethrow;
      }
      if (!valid()) throw StateError('Session attachment revoked');
      select(session);
      _rememberRunFeatures(connection, client);
      notifyListeners();
    } finally {
      core?.close();
      client?.close();
      attachingRemote = false;
      notifyListeners();
    }
  }

  bool _canRefreshRemoteHistory(ChatSession session) =>
      !identical(_dispatchingSession, session) &&
      !identical(_preparing?.source.session, session) &&
      !_outbox.any((item) => identical(item.session, session)) &&
      !_uncertain.containsKey(session) &&
      !_preparedInputs.containsKey(session.id) &&
      (runs[session.id] == null || runs[session.id]!.committed);

  Future<AgentControlsController?> openRunControls({
    required bool Function() isOwnerCurrent,
  }) async {
    final session = current;
    final op = currentRun;
    if (session == null || op?.runId == null) return null;
    final connection =
        connections.where((c) => c['id'] == session.connectionId).firstOrNull;
    if (connection == null) return null;
    final operation = op!;
    final key = operation.key;
    final runId = operation.runId!;
    final epoch = connection['authorityEpoch'];
    final origin = connection['url'];
    final controlRevision = _controlRevisions[connection] ??= Object();
    final selection = selectionGeneration;
    final generation = _runsGeneration;
    bool valid() =>
        isOwnerCurrent() &&
        generation == _runsGeneration &&
        selection == selectionGeneration &&
        !changingConnection &&
        identical(controlRevision, _controlRevisions[connection]) &&
        identical(current, session) &&
        _active(session, connection, operation) &&
        operation.key == key &&
        operation.runId == runId &&
        connection['authorityEpoch'] == epoch &&
        connection['url'] == origin &&
        operation.data['authorityEpoch'] == epoch;
    if (!valid()) return null;
    final client = await _runClient(connection, isCurrent: valid);
    try {
      client.bind(operation);
      if (!await client.discover() || !valid()) {
        client.close();
        return null;
      }
      final revision = _connectionRevisions[connection] ??= Object();
      final scope = ControlScope(
        sourceId: session.id,
        runId: runId,
        authorityToken: revision,
      );
      final controller = AgentControlsController(
        ControlBoundary(
          scope: scope,
          isCurrentAuthority: (s) => valid() && s.matches(scope),
          supportsAction: (action) =>
              valid() &&
              (action == ControlAction.approval
                  ? client.canApprove
                  : client.canClarify(operation.snapshot)),
          refresh: () async {
            final snapshot = await client.status(
              operation,
              _ledger,
              isCurrent: valid,
            );
            if (!valid()) throw StateError('Stale controls');
            await _reconcile(session, connection, operation);
            if (!valid()) throw StateError('Stale controls');
            // A control's fresh GET can observe terminal completion before
            // the normal poll. Wake only through the existing durable,
            // source-bound queue gate; explicit pauses remain intact.
            _scheduleSelectedQueue();
            final controls =
                PendingControlsSnapshot.fromJson(scope, snapshot.data);
            _statusObserved(operation, isCurrent: valid);
            notifyListeners();
            return controls;
          },
          postDecision: (action, body) async {
            if (!valid()) throw StateError('Stale controls');
            final (code, data) = await client.respondControl(
              operation,
              requestId: body['request_id'] as String,
              generation: body['execution_generation'] as int,
              choice: action == ControlAction.approval
                  ? body['choice'] as String
                  : null,
              answer: action == ControlAction.clarify
                  ? body['answer'] as String
                  : null,
              isCurrent: valid,
            );
            return ControlPostResult(code, data);
          },
        ),
        redact: client.redactKnownSecrets,
        onDispose: client.close,
      );
      await controller.refresh();
      if (!valid()) {
        controller.dispose();
        return null;
      }
      return controller;
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  /// Initial native-run suspension need not block a foreground setup flow.
  /// Actual lifecycle/owner revocation always pauses catalogs by default.
  void pauseRuns(bool paused, {bool pauseCatalog = true}) {
    if (_runsPaused && !paused) {
      // A genuine return grants another bounded read-only check, not permission
      // to replay a missing admission or clear an explicit queue pause.
      for (final op in runs.values) {
        if (!op.committed &&
            !op.snapshot.terminal &&
            (op.runId != null || op.data['attempted'] == true) &&
            (_statusFailures[op.key] ?? 0) > _pollLimit(op)) {
          _statusFailures[op.key] = 1;
          _observationProblems[op.key] = op.runId != null
              ? 'Reconnecting to check your reply'
              : _syncReceived.contains(op.key)
                  ? 'Message received. Refreshing chat for your reply'
                  : 'Refreshing chat to sync your reply';
        }
      }
    }
    if (paused) {
      _canonical?.suspend();
      _runsGeneration++;
      _catalogGeneration++;
    }
    _catalogPaused = paused && pauseCatalog;
    _runsPaused = paused;
    _poll?.cancel();
    if (!paused && !_disposed) _schedulePoll();
    // Revoke authority above immediately, but notify after owner lifecycle
    // callbacks finish: widgets may be locked and activity must pause before
    // validating its temporarily suspended observation authority.
    Future.microtask(notifyListeners);
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (_runsPaused || _disposed || !runs.values.any(_canPoll)) {
      return;
    }
    final failures = runs.values
        .where(_canPoll)
        .map((op) => _statusFailures[op.key] ?? 0)
        .reduce((a, b) => a < b ? a : b);
    final delaySeconds = failures == 0 ? 2 : min(1 << failures, 8);
    _poll = Timer(Duration(seconds: delaySeconds), () async {
      for (final session in sessions.toList()) {
        if (_runsPaused || _disposed) break;
        final op = runs[session.id];
        if (op != null && _canPoll(op)) {
          await checkRunStatus(sessionId: session.id, automatic: true);
        }
      }
      _schedulePoll();
    });
  }

  Future<RunClient> _runClient(
    Map<String, dynamic> connection, {
    required bool Function() isCurrent,
  }) async {
    final key =
        await store.readConnectionSecret(connection['id'] as String) ?? '';
    if (!isCurrent()) {
      throw StateError('Connection changed');
    }
    return (runClientFactory ?? ((root, key) => RunClient(root, key)))(
      connection['url'] as String? ?? 'http://127.0.0.1:8642',
      key,
    );
  }

  bool _active(
    ChatSession session,
    Map<String, dynamic> connection, [
    RunOperation? op,
  ]) =>
      !_disposed &&
      !_runsPaused &&
      !_loadFailed &&
      sessions.contains(session) &&
      connections.any((c) => identical(c, connection)) &&
      (op == null || identical(runs[session.id], op));

  Future<void> _commitRun(
    ChatSession session,
    Map<String, dynamic> connection,
    RunOperation op,
  ) async {
    final generation = _runsGeneration;
    bool isCurrent() =>
        generation == _runsGeneration && _active(session, connection, op);
    if (!isCurrent()) return;
    // Do not expose committed=true until both history and journal are durable.
    final durable = RunOperation({
      ...op.data,
      'committed': true,
      'journalDirty': false,
    });
    await _ledger.save(durable, isCurrent: isCurrent);
    if (!isCurrent()) return;
    op.data['committed'] = true;
    op.data['journalDirty'] = false;
    if (op.snapshot.terminal) {
      _recoveryPauses.remove(session);
    }
  }

  Future<void> _reconcile(
    ChatSession session,
    Map<String, dynamic> connection,
    RunOperation op, {
    String? inputMessageId,
    String? replyMessageId,
    DateTime? replyTimestamp,
  }) async {
    final generation = _runsGeneration;
    bool isCurrent() =>
        generation == _runsGeneration && _active(session, connection, op);
    if (!isCurrent()) return;
    final snapshot = op.snapshot;
    if (snapshot.terminal) {
      _streamText.remove(op.key);
      _streamCursors.remove(op.key);
      _observationProblems.remove(op.key);
      _statusFailures.remove(op.key);
      _syncReceived.remove(op.key);
    }
    if (!_runUpdates.isClosed) _runUpdates.add(snapshot);
    if (!_scopedRunUpdates.isClosed) {
      final revision = _connectionRevisions[connection] ??= Object();
      final epoch = op.data['authorityEpoch'];
      final root = connection['url'];
      _scopedRunUpdates.add(
        ScopedRunSnapshot(
          localChatId: session.id,
          connectionId: session.connectionId,
          connectionRevision: revision,
          operationKey: op.key,
          originalAuthority: {
            'origin': op.data['origin'] as String?,
            'authorityEpoch': op.data['authorityEpoch'] as String?,
            'credentialScope': op.data['scope'] as String?,
          },
          snapshot: snapshot,
          originalConnection: connection,
          eventsSupported: _activityEvents[connection] == true,
          // Read-only telemetry survives operation replacement, never controls.
          isCurrent: isCurrent,
          isObservable: () =>
              _active(session, connection) &&
              epoch == connection['authorityEpoch'] &&
              root == connection['url'],
        ),
      );
    }
    if (snapshot.terminal && !op.committed) op.data['journalDirty'] = true;
    if (snapshot.state == RunState.completed) {
      if (snapshot.output.trim().isEmpty) {
        _terminalProblems[session] = _emptyFinalMessage;
      } else {
        _terminalProblems.remove(session);
      }
      final marker = 'run-${op.key}';
      if (!session.messages.any((m) => m.id == marker)) {
        final now = DateTime.now().toUtc().toIso8601String();
        final replyIso = replyTimestamp?.toUtc().toIso8601String() ?? now;
        session.messages.addAll([
          ChatMessage(
            role: 'user',
            content: op.input,
            photos: op.photos,
            id: 'input-${op.key}',
            metadata: {
              'timestamp': now,
              if (inputMessageId != null) 'serverMessageId': inputMessageId,
            },
          ),
          ChatMessage(
            role: 'model',
            content: snapshot.output,
            id: marker,
            metadata: {
              'timestamp': replyIso,
              if (replyMessageId != null) 'serverMessageId': replyMessageId,
              if (snapshot.output.trim().isNotEmpty)
                'authoritativeCompletion': true,
            },
          ),
        ]);
        if (snapshot.output.trim().isNotEmpty &&
            op.data['alertClaimed'] != true) {
          op.data['alertClaimed'] = true;
          try {
            await _ledger.save(op, isCurrent: isCurrent);
            if (!isCurrent()) return;
            onReplyReceived?.call(session.id);
          } catch (_) {
            if (!isCurrent()) return;
          }
        }
      }
      if (!isCurrent()) return;
      if (snapshot.output.trim().isNotEmpty) {
        await _recordCompletion(session, marker);
      }
      try {
        await store.saveChats(sessions.map((s) => s.toJson()).toList());
        if (!isCurrent()) return;
        await _commitRun(session, connection, op);
        if (!isCurrent()) return;
        unsavedChanges = false;
        error = null;
      } catch (_) {
        if (!isCurrent()) return;
        unsavedChanges = true;
        // unsavedChanges gates every queue without replacing explicit pauses.
        error =
            'Response received but not saved. Try saving again; do not resend.';
      }
    } else if (snapshot.terminal) {
      final result = snapshot.state == RunState.failed
          ? 'The server could not finish this reply'
          : 'This reply was stopped';
      _paused[session] =
          '$result. Prior work may have had side effects. Review before choosing Resume.';
      try {
        await _commitRun(session, connection, op);
        if (!isCurrent()) return;
        error = '$result. Prior work may have had side effects.';
      } catch (_) {
        if (!isCurrent()) return;
        unsavedChanges = true;
        error = 'Run result not saved. Try saving again; do not resend.';
      }
    }
    if (snapshot.state == RunState.unknown ||
        snapshot.state == RunState.unrecognized) {
      _recoveryPauses[session] =
          'The reply is not confirmed. Check its status before queued messages continue. Nothing will be sent again.';
    }
    if (isCurrent()) notifyListeners();
  }

  /// Refreshes server session history for an attempted run whose admission ACK
  /// was lost, matching the pending input by string match to recover a missing
  /// run ID or completed reply without ever resending the prompt.
  ///
  /// Returns `true` when a valid `run_id` was recovered while the reply is
  /// still in progress so the caller can immediately poll `/v1/runs/{run_id}`.
  Future<bool> _syncAttemptedRun(
    ChatSession session,
    Map<String, dynamic> connection,
    RunOperation op,
    RunClient client, {
    required bool Function() isCurrent,
    required bool manual,
  }) async {
    final pendingPhotos = op.photos;
    final knownPhotoUrls = {
      for (final photo in pendingPhotos) photo.dataUrl,
      for (final message in session.messages)
        for (final photo in message.photos) photo.dataUrl,
    }.lookup;
    final matchInlinePhotos = pendingPhotos.isNotEmpty ||
        session.messages.any((m) => m.photos.isNotEmpty);
    final rows = <Map<String, dynamic>>[];
    final seen = <Object>{};
    var offset = 0;
    for (var pages = 0;; pages++) {
      if (pages == 256) {
        throw StateError('History exceeds the bounded sync window');
      }
      final page = await client.sessionMessages(
        op,
        offset: offset,
        limit: matchInlinePhotos ? 20 : 100,
        matchInlinePhotos: matchInlinePhotos,
        isCurrent: isCurrent,
      );
      if (!isCurrent() || page.sessionId != op.sessionId) {
        throw StateError('Session identity changed');
      }
      final pagination = page.pagination;
      final returned = pagination['returned'] as int? ?? page.messages.length;
      final limit = pagination['limit'] as int? ?? 100;
      for (final row in page.messages) {
        final id = row['id'];
        if (id is! String && id is! int || seen.add(id!)) {
          rows.add(matchInlinePhotos
              ? retainKnownRunPhotoUrls(row, knownPhotoUrls)
              : row);
        }
      }
      offset += returned;
      final more = pagination['has_more'];
      if (returned == 0 || (more is bool ? !more : returned < limit)) break;
    }
    if (!isCurrent()) return false;
    final match = matchAttemptedRunInHistory(
      existingMessages: session.messages,
      pendingInput: op.input,
      pendingPhotos: pendingPhotos,
      rawRows: rows,
    );
    switch (match.status) {
      case RunHistorySyncStatus.matchedReply:
        if (match.recoveredRunId != null && op.runId == null) {
          op.data['run'] = match.recoveredRunId;
        }
        if (match.precedingMessages.isNotEmpty) {
          session.messages.addAll(match.precedingMessages);
        }
        op.data['snapshot'] = {
          if (op.runId != null) 'run_id': op.runId,
          'status': 'completed',
          'output': match.replyText!,
        };
        try {
          await _ledger.save(op, isCurrent: isCurrent);
        } catch (_) {
          // A durability failure must not discard the answer already synced.
          op.data['journalDirty'] = true;
        }
        if (!isCurrent()) return false;
        _statusObserved(op, isCurrent: isCurrent);
        await _reconcile(
          session,
          connection,
          op,
          inputMessageId: match.matchedUserMessageId,
          replyMessageId: match.matchedReplyMessageId,
          replyTimestamp: match.replyTimestamp,
        );
        if (match.trailingMessages.isNotEmpty &&
            isCurrent() &&
            op.committed &&
            !unsavedChanges) {
          session.messages.addAll(match.trailingMessages);
          try {
            await persist();
          } catch (_) {
            if (!isCurrent()) return false;
            unsavedChanges = true;
            error =
                'Updated history could not be saved. Try saving again; nothing was sent.';
          }
        }
        return false;
      case RunHistorySyncStatus.matchedUserPending:
        if (match.recoveredRunId != null && op.runId == null) {
          op.data['run'] = match.recoveredRunId;
          await _ledger.save(op, isCurrent: isCurrent);
          if (!isCurrent()) return false;
          _syncReceived.remove(op.key);
          return true;
        }
        _syncUnavailable(
          session,
          op,
          receivedOnServer: true,
          manual: manual,
        );
        return false;
      case RunHistorySyncStatus.notFound:
      case RunHistorySyncStatus.diverged:
        _syncUnavailable(
          session,
          op,
          receivedOnServer: false,
          manual: manual,
        );
        return false;
    }
  }

  Future<void> checkRunStatus({
    String? sessionId,
    bool acknowledgeUnknown = false,
    bool automatic = false,
  }) async {
    if (_disposed || _runsPaused || busy) return;
    final session =
        sessions.where((s) => s.id == (sessionId ?? current?.id)).firstOrNull;
    if (session == null) return;
    final op = runs[session.id];
    if (op == null) return;
    final generation = _runsGeneration;
    RunClient? client;
    busy = true;
    notifyListeners();
    try {
      final c = connections.singleWhere((c) => c['id'] == session.connectionId);
      bool isCurrent() =>
          generation == _runsGeneration && _active(session, c, op);
      bool hasOriginalAuthority() {
        if (op.data['authorityEpoch'] == c['authorityEpoch']) return true;
        const problem =
            'This reply belongs to a removed or replaced connection. Nothing was sent again.';
        _statusFailures[op.key] = _pollLimit(op) + 1;
        _observationProblems[op.key] = problem;
        _recoveryPauses[session] = problem;
        if (identical(current, session)) error = problem;
        return false;
      }

      // A replacement connection must not even lend its key to the old run.
      if (!hasOriginalAuthority()) return;
      client = await _runClient(c, isCurrent: isCurrent);
      if (!isCurrent() || !hasOriginalAuthority()) return;
      client.bind(op);
      if (op.snapshot.terminal) {
        await _reconcile(session, c, op);
        return;
      }
      if (!await client.discover()) throw StateError('Runs unavailable');
      if (!isCurrent()) return;
      _rememberRunFeatures(c, client);
      if (op.runId == null) {
        if (op.data['attempted'] == true) {
          final recoveredRunId = await _syncAttemptedRun(
            session,
            c,
            op,
            client,
            isCurrent: isCurrent,
            manual: !automatic,
          );
          if (!recoveredRunId || !isCurrent()) return;
        } else {
          // A prepared operation that provably never reached dispatch may still
          // be sent by an explicit user action. Uncertain sends never are.
          await client.submit(op, _ledger, isCurrent: isCurrent);
        }
      }
      if (op.runId != null) {
        if (acknowledgeUnknown) {
          await client.resolveUnknown(
            op,
            _ledger,
            acknowledgedSideEffects: true,
            isCurrent: isCurrent,
            onObserved: () async {
              _statusObserved(op, isCurrent: isCurrent);
              await _reconcile(session, c, op);
            },
          );
        } else {
          await client.status(op, _ledger, isCurrent: isCurrent);
        }
        if (!isCurrent()) return;
        _statusObserved(op, isCurrent: isCurrent);
        await _reconcile(session, c, op);
      }
      error ??= op.runId == null
          ? 'Admission saved; outcome unknown. Refresh without sending again.'
          : null;
    } catch (_) {
      final connection =
          connections.where((c) => c['id'] == session.connectionId).firstOrNull;
      if (generation != _runsGeneration ||
          connection == null ||
          !_active(session, connection, op) ||
          op.data['authorityEpoch'] != connection['authorityEpoch']) {
        return;
      }
      // A resolution can become obsolete after its authoritative status read.
      // Preserve terminal settlement rather than turning that into a read error.
      if (op.snapshot.terminal) {
        await _reconcile(session, connection, op);
        return;
      }
      if (op.runId != null) {
        _statusUnavailable(session, op);
      } else if (op.data['attempted'] == true) {
        _syncUnavailable(session, op, manual: !automatic);
      } else {
        _observationProblems[op.key] =
            'Could not reach the server to send your message. Keep the original connection and try again.';
      }
    } finally {
      client?.close();
      busy = false;
      // A manual check after exhaustion may observe ongoing work. Restore the
      // existing bounded poll owner; a running snapshot alone is not progress.
      _schedulePoll();
      _scheduleSelectedQueue();
      notifyListeners();
    }
  }

  Future<_DispatchResult?> _sendRun(
    ChatSession session,
    Map<String, dynamic> connection,
    String text,
    _DispatchPermission permission,
  ) async {
    if (connection['type'] != 'hermes') return null;
    // An injected direct-core test hook must not bypass Android's native policy.
    final photos = permission.source.photos;
    if (!_runDiscovery && !usesRunStatusSync && photos.isEmpty) return null;
    final previous = runs[session.id];
    final generation = _runsGeneration;
    bool isCurrent() =>
        generation == _runsGeneration &&
        _active(session, connection) &&
        !permission.revoked &&
        _bound(permission.source) &&
        !_background &&
        identical(runs[session.id], previous);
    final client = await _runClient(connection, isCurrent: isCurrent);
    try {
      if (!isCurrent()) throw StateError('Stale run');
      final supported = await client.discover();
      _rememberRunFeatures(connection, client);
      if (!isCurrent()) throw StateError('Stale run');
      if (photos.isNotEmpty && !client.photosSupported) {
        throw const ProviderException(
          'The original Hermes API did not verify photo input. The photo message is held.',
        );
      }
      if (!supported) {
        if (usesRunStatusSync) {
          throw const ProviderException(
            'This Hermes connection needs durable Runs for Android replies. '
            'Enable Runs on the original server, then try again. Nothing was sent.',
          );
        }
        if (previous != null || session.remoteSessionId != null) {
          throw StateError('Existing run requires its original Runs authority');
        }
        return null;
      }
      if (previous != null &&
          previous.data['authorityEpoch'] != connection['authorityEpoch']) {
        throw StateError('Original connection creation required');
      }
      final op = await client.prepare(
        _ledger,
        authorityEpoch: connection['authorityEpoch'] as String?,
        isCurrent: isCurrent,
        local: session.id,
        existingSessionId: session.remoteSessionId,
        input: text,
        photos: photos,
        model: session.model,
        provider: session.upstreamProvider,
        instructions: permission.source.captured.instructions,
        personaId: permission.source.captured.personaId,
        personaRevision: permission.source.captured.revision,
        history: session.messages
            .map(
              (m) => {
                'role': m.role == 'model' ? 'assistant' : m.role,
                'content': m.content,
              },
            )
            .toList(),
        previous: previous,
      );
      if (!isCurrent()) throw StateError('Stale run');
      runs[session.id] = op;
      _dispatchRun = op;
      await client.submit(
        op,
        _ledger,
        isCurrent: () =>
            generation == _runsGeneration &&
            _active(session, connection, op) &&
            !permission.revoked &&
            _bound(permission.source) &&
            !_background,
      );
      if (op.runId != null && !_disposed && !_runsPaused) {
        await client.status(
          op,
          _ledger,
          isCurrent: () =>
              generation == _runsGeneration && _active(session, connection, op),
        );
        if (generation != _runsGeneration ||
            !_active(session, connection, op)) {
          return _DispatchResult.admitted;
        }
        _statusObserved(
          op,
          isCurrent: () =>
              generation == _runsGeneration && _active(session, connection, op),
        );
        await _reconcile(session, connection, op);
      }
      _schedulePoll();
      return op.committed && op.snapshot.state == RunState.completed
          ? _DispatchResult.completed
          : _DispatchResult.admitted;
    } on PreparedRunRevoked catch (e) {
      // Retain only in the captured original chat; the journal owns this input,
      // so the queue must not restore another copy or allocate another key.
      runs[session.id] = e.operation;
      _paused[session] =
          'Not sent. Prepared operation held. Reconnect using the original operation.';
      error = _paused[session];
      return _DispatchResult.admitted;
    } catch (_) {
      final op = runs[session.id];
      if (usesRunStatusSync &&
          op != null &&
          !identical(op, previous) &&
          op.runId != null &&
          (generation != _runsGeneration ||
              !_active(session, connection, op))) {
        // A late foreground read has no authority after suspension/replacement.
        // Retain its durable admission; returning grants fresh read-only sync.
        return _DispatchResult.admitted;
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> load() async {
    try {
      await organization.load();
      final data = await store.load();
      connections.addAll(data.connections);
      sessions.addAll(data.chats.map(ChatSession.fromJson));
      for (final session in sessions) {
        final op = await _ledger.load(session.id);
        if (op != null) runs[session.id] = op;
      }
      if (sessions.isNotEmpty) current = sessions.last;
      await _restorePrepared();
      if (current == null && sessions.isNotEmpty) current = sessions.last;
      for (final session in sessions) {
        for (final message in session.messages) {
          if (message.metadata['authoritativeCompletion'] == true &&
              message.id != null) {
            _completionBacklog.add((identityOf(session), message.id!));
          }
        }
      }
      await _flushOrganization();
    } catch (_) {
      _loadFailed = true;
      error =
          'Saved data could not be read. Nothing has been overwritten. Restart after restoring your local data.';
    }
    loading = false;
    notifyListeners();
  }

  ProviderConfig config(Map<String, dynamic> c, String key) => ProviderConfig(
        id: c['id'],
        name: c['name'],
        type: ProviderType.values.byName(c['type']),
        apiKey: key,
        baseUrl: c['url'],
      );
  bool isCurrentConnection(Map<String, dynamic> connection) =>
      !_disposed && connections.any((c) => identical(c, connection));

  Future<SaathiCore> coreFor(Map<String, dynamic> c) async {
    final core = coreFactory();
    try {
      core.addProvider(
          config(c, await store.readConnectionSecret(c['id']) ?? ''));
      return core;
    } catch (_) {
      core.close();
      rethrow;
    }
  }

  Future<void> addConnection(Map<String, dynamic> c, String key) async {
    if (!canChangeConnections) {
      throw StateError('Connection unavailable or work in progress');
    }
    _revokeCanonicalMutation();
    changingConnection = true;
    notifyListeners();
    try {
      final created = {
        ...c,
        if (c['type'] == 'hermes') 'authorityEpoch': runIdentity(),
      };
      await store.saveConnection(created, apiKey: key);
      if (!_disposed) connections.add(created);
    } on StorageRecoveryException {
      _failClosed();
      rethrow;
    } finally {
      changingConnection = false;
      notifyListeners();
    }
  }

  bool changingConnection = false;
  // Accepted detail edits retain an original-source validator for storage-only
  // retry. Keep that source intact through both the write and uncertain rollback.
  bool get canChangeConnections =>
      !_disposed &&
      !loading &&
      !busy &&
      !changingConnection &&
      !_loadFailed &&
      !organization.saving &&
      !organization.hasUnsavedChanges;
  void _failClosed() {
    _loadFailed = true;
    error =
        'Secure storage recovery could not be confirmed. Connections are read-only; restart after checking storage.';
  }

  bool isSessionReadOnly(ChatSession session) {
    final activeCanonical = identical(session, current)
        ? canonical
        : (identical(session, _canonicalSession) ? _canonical : null);
    return _loadFailed ||
        _quarantinedInputs.contains(session) ||
        (connections.any(
              (c) =>
                  c['id'] == session.connectionId &&
                  c['type'] == 'hermesGateway',
            ) &&
            (activeCanonical == null || !activeCanonical.connected)) ||
        !connections.any((c) => c['id'] == session.connectionId);
  }

  List<ChatSession> orderedSessions([Iterable<ChatSession>? source]) {
    final candidates = (source ?? sessions.reversed).toList();
    final indexed = candidates.asMap().entries.toList();
    indexed.sort((a, b) {
      final aReadOnly = isSessionReadOnly(a.value);
      final bReadOnly = isSessionReadOnly(b.value);
      if (aReadOnly != bReadOnly) return aReadOnly ? 1 : -1;
      final aTime = a.value.latestMessageAt;
      final bTime = b.value.latestMessageAt;
      if (aTime != null && bTime != null) {
        final cmp = bTime.compareTo(aTime);
        if (cmp != 0) return cmp;
      } else if (aTime != null || bTime != null) {
        return aTime != null ? -1 : 1;
      }
      return a.key.compareTo(b.key);
    });
    return [for (final entry in indexed) entry.value];
  }

  bool get readOnly =>
      _loadFailed || (current != null && isSessionReadOnly(current!));

  void _checkMutation(
    String id, {
    bool changesConnection = true,
    bool allowDuringDirectStream = false,
  }) {
    final busyBlocked = busy &&
        !(allowDuringDirectStream && _directStreaming && !unsavedChanges);
    if (_disposed ||
        loading ||
        busyBlocked ||
        changingConnection ||
        _loadFailed ||
        (changesConnection &&
            (organization.saving || organization.hasUnsavedChanges)) ||
        !connections.any((c) => c['id'] == id)) {
      throw StateError('Connection unavailable or work in progress');
    }
  }

  Future<void> updateConnection(
    String id,
    Map<String, dynamic> values, {
    String? apiKey,
  }) async {
    _checkMutation(id);
    _revokeCanonicalMutation();
    final old = connections.singleWhere((c) => c['id'] == id);
    _controlRevisions[old] = Object();
    final revised =
        old['type'] != values['type'] || old['url'] != values['url'];
    final next = <String, dynamic>{
      ...old,
      ...values,
      if (old['type'] == 'hermes' ||
          values['type'] == 'hermes' ||
          old.containsKey('authorityEpoch') ||
          apiKey != null)
        'authorityEpoch':
            revised || apiKey != null ? runIdentity() : old['authorityEpoch'],
      'id': revised
          ? List.generate(
              24,
              (_) => Random.secure()
                  .nextInt(256)
                  .toRadixString(16)
                  .padLeft(2, '0'),
            ).join()
          : id,
    };
    changingConnection = true;
    notifyListeners();
    try {
      await store.changeConnection(id, replacement: next, apiKey: apiKey);
      if (_disposed) return;
      connections[connections.indexOf(old)] = next;
    } on StorageRecoveryException {
      _failClosed();
      rethrow;
    } finally {
      changingConnection = false;
      notifyListeners();
    }
  }

  Future<void> deleteConnection(String id) async {
    _checkMutation(id);
    _controlRevisions[connections.singleWhere((c) => c['id'] == id)] = Object();
    _revokeCanonicalMutation();
    changingConnection = true;
    notifyListeners();
    try {
      await store.changeConnection(id);
      if (_disposed) return;
      connections.removeWhere((c) => c['id'] == id);
    } on StorageRecoveryException {
      _failClosed();
      rethrow;
    } finally {
      changingConnection = false;
      notifyListeners();
    }
  }

  Future<List<ModelInfo>> discover(
    Map<String, dynamic> c, {
    bool Function()? isCurrent,
    Future<void>? cancelTrigger,
  }) async {
    final generation = catalogGeneration;
    bool valid() =>
        canDiscoverModels &&
        generation == catalogGeneration &&
        (c['type'] != 'hermes' || isCurrentConnection(c)) &&
        !changingConnection &&
        (isCurrent?.call() ?? true);
    if (!valid()) throw StateError('Stale catalog');
    final core = coreFactory();
    try {
      final key = await store.readConnectionSecret(c['id']) ?? '';
      if (!valid()) throw StateError('Stale catalog');
      core.addProvider(config(c, key));
      final result = await core.discoverModels(
        c['id'],
        isCurrent: valid,
        cancelTrigger: cancelTrigger,
      );
      if (!valid()) throw StateError('Stale catalog');
      return result;
    } finally {
      core.close();
    }
  }

  /// Creates and selects a new local conversation on [c].
  ///
  /// When [personaId] is supplied on a direct-model connection, validates and
  /// attaches the shared persona before selecting the new session, rolling back
  /// the created session on confirmed metadata save failures.
  Future<void> newSession(
    Map<String, dynamic> c,
    String model,
    String prompt, {
    String? upstreamProvider,
    String? personaId,
  }) async {
    if (upstreamProvider != null && !isCurrentConnection(c)) {
      throw StateError('Stale connection');
    }
    final attachPersona = personaId != null &&
        personaId.isNotEmpty &&
        const {'openai', 'anthropic', 'gemini'}.contains(c['type']);
    if (attachPersona) {
      if (!organization.loaded ||
          organization.saving ||
          organization.hasUnsavedChanges) {
        throw StateError(
            'Conversation metadata is not ready for persona edits');
      }
      if (!organization.personas.any((p) => p.id == personaId)) {
        throw StateError('Selected persona no longer exists');
      }
    }
    // A new chat leaves the accepted edit's original source/session intact.
    _checkMutation(
      c['id'] as String,
      changesConnection: false,
      allowDuringDirectStream: true,
    );
    // Starting a new-chat transition spends native input/control authority even
    // when its subsequent history write fails and the old chat remains visible.
    if (identical(current, _canonicalSession)) _canonical?.revokeInput();
    final session = ChatSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      connectionId: c['id'],
      upstreamProvider: upstreamProvider,
      model: model,
      systemPrompt: prompt,
    );
    sessions.add(session);
    try {
      await persist();
    } catch (_) {
      sessions.remove(session);
      rethrow;
    }
    if (attachPersona) {
      final identity = identityOf(session);
      try {
        await organization.edit(
          identity,
          displayName: '',
          personaId: personaId,
          policy: PersonaEditPolicy.localInstructions,
          pendingReason: null,
          revalidatePersonaChange: () => pendingPersonaReason(identity),
        );
      } catch (err) {
        if (err is OrganizationWriteFailure && !err.rollbackConfirmed) {
          select(session);
          rethrow;
        }
        if (organization.hasUnsavedChanges) {
          organization.discardPendingEdit();
        }
        sessions.remove(session);
        try {
          await persist();
        } catch (_) {
          sessions.add(session);
          select(session);
        }
        rethrow;
      }
    }
    // Successful local creation follows the same source-bound pause policy as
    // selecting history or continuing a remote chat. A lease alone is not a pause.
    select(session);
  }

  bool openNotificationConversation(String id) {
    if (_disposed || loading || !validConversationId(id)) return false;
    final found = sessions.where((s) => s.id == id);
    if (found.length != 1) return false;
    select(found.single);
    return true;
  }

  void select(ChatSession session) {
    if (!identical(current, session)) {
      if (_canonicalSession != null && identical(current, _canonicalSession)) {
        _canonical?.revokeInput();
      }
      pauseQueue(
        'Queue paused because the conversation changed. Return to the original conversation and choose Resume.',
      );
    }
    current = session;
    if (!_loadFailed) error = null;
    notifyListeners();
  }

  Future<void>? _persistTail;
  int _persistVersion = 0;

  Future<void> persist() async {
    if (_loadFailed) {
      throw StateError('Saved data must be recovered before writing');
    }
    final previous = _persistTail;
    final done = Completer<void>();
    _persistTail = done.future;
    try {
      if (previous != null) await previous;
      if (_loadFailed) {
        throw StateError('Saved data must be recovered before writing');
      }
      final version = ++_persistVersion;
      await store.saveChats(sessions.map((s) => s.toJson()).toList());
      if (version == _persistVersion &&
          _canonicalQueueSaveRetry == null &&
          _canonicalSaveRetry == null) {
        unsavedChanges = false;
      }
    } finally {
      if (identical(_persistTail, done.future)) _persistTail = null;
      done.complete();
    }
  }

  Future<void> retrySave() async {
    final retryQueue = _canonicalQueueSaveRetry;
    if (retryQueue != null) {
      if (_disposed || _loadFailed || busy || canonicalQueueSaving) return;
      try {
        await retryQueue();
        _canonicalQueueSaveRetry = null;
        unsavedChanges = _canonicalSaveRetry != null;
        error = null;
      } catch (_) {
        unsavedChanges = true;
        error =
            'The held queue is still not saved. Try saving again; nothing was sent.';
      }
      notifyListeners();
      return;
    }
    if (_canonicalSaveRetry != null) {
      if (_disposed || _loadFailed || busy) return;
      await refreshCanonical();
      return;
    }
    // Runs lifecycle suspension must not disable legacy history-only recovery.
    final nativePaused = _runsPaused && runs.isNotEmpty;
    if (_disposed || nativePaused || _loadFailed || busy) return;
    final captured = <(ChatSession, Map<String, dynamic>, RunOperation)>[];
    for (final session in sessions.toList()) {
      final op = runs[session.id];
      final connection =
          connections.where((c) => c['id'] == session.connectionId).firstOrNull;
      if (op != null &&
          connection != null &&
          op.snapshot.terminal &&
          op.data['authorityEpoch'] == connection['authorityEpoch']) {
        captured.add((session, connection, op));
      }
    }
    busy = true;
    try {
      await store.saveChats(sessions.map((s) => s.toJson()).toList());
      if (_disposed || (_runsPaused && runs.isNotEmpty) || _loadFailed) return;
      for (final (session, connection, op) in captured) {
        if (!_active(session, connection, op)) return;
        if (op.snapshot.state == RunState.completed &&
            !session.messages.any((m) => m.id == 'run-${op.key}')) {
          continue;
        }
        await _commitRun(session, connection, op);
        if (!_active(session, connection, op)) return;
      }
      await _clearSavedPrepared();
      unsavedChanges = false;
      error = null;
    } catch (_) {
      if (_disposed || (_runsPaused && runs.isNotEmpty) || _loadFailed) return;
      unsavedChanges = true;
      error =
          'Conversation is still not saved. Keep Saathi open and try again.';
    } finally {
      busy = false;
      _scheduleSelectedQueue();
      notifyListeners();
    }
  }

  bool get canDeleteConversation =>
      !busy &&
      current != null &&
      !organization.saving &&
      !organization.hasUnsavedChanges;

  Future<void> clear() async {
    if (organization.saving || organization.hasUnsavedChanges) {
      throw StateError('Save or recover conversation details before deleting');
    }
    if (busy || current == null) return;
    // A fresh ID also clears any backend-owned state; never re-use a cleared thread.
    final old = current!;
    if (_preparedInputs.containsKey(old.id)) {
      throw StateError(
          'Resolve or explicitly discard held input before deleting this conversation');
    }
    if (identical(old, _canonicalSession)) _canonical?.revokeInput();
    final index = sessions.indexOf(old);
    sessions.remove(old);
    current = null;
    try {
      await persist();
    } catch (_) {
      sessions.insert(index, old);
      current = old;
      rethrow;
    }
    notifyListeners();
  }

  Future<bool> send(String text) async {
    if (!_validInput(text, current)) return false;
    if (_draining ||
        organizationBlocked ||
        unsavedChanges ||
        _background ||
        _paused.containsKey(current) ||
        outbox.isNotEmpty) {
      return false;
    }
    final result = await _dispatch(text);
    return result == _DispatchResult.completed ||
        result == _DispatchResult.admitted;
  }

  bool _validInput(String text, ChatSession? session) {
    if (_disposed) return false;
    if (text.length > maxInputLength ||
        (session != null &&
            organization
                    .captureInstructions(
                      identityOf(session),
                      fallback: session.systemPrompt,
                    )
                    .instructions
                    .length >
                16000)) {
      error =
          'Input is too large. Use at most 262,144 characters and 16,000 instruction characters. Your draft was not sent.';
      notifyListeners();
      return false;
    }
    return true;
  }

  /// Persists the truthful outcome of a user-stopped direct-model stream.
  ///
  /// Partial output is kept with explicit incomplete metadata and is never
  /// marked as an authoritative completion or unread alert. When no text
  /// arrived before stopping, no fake reply is inserted and the prepared input
  /// is discarded (failing closed into [_uncertain] if storage discard fails).
  Future<void> _completeStoppedDirectReply(
    ChatSession session, {
    required String input,
    required String partialText,
    required QueuedFollowup source,
    Map<String, dynamic> metadata = const {},
  }) async {
    if (partialText.trim().isNotEmpty) {
      final now = DateTime.now().toUtc().toIso8601String();
      session.messages.addAll([
        ChatMessage(
          role: 'user',
          content: input,
          metadata: {'timestamp': now},
        ),
        ChatMessage(
          role: 'model',
          content: partialText,
          id: source.replyId,
          metadata: {
            ...ReportedUsage.fromMetadata(metadata).toMetadata(),
            'timestamp': parseMessageTimestamp(metadata['timestamp'])
                    ?.toIso8601String() ??
                now,
            'stoppedByUser': true,
            'incomplete': true,
          },
        ),
      ]);
      _terminalProblems[session] =
          'Stopped. Partial reply kept and may be incomplete. Nothing was resent.';
      try {
        await persist();
        await _clearSavedPrepared();
      } catch (_) {
        unsavedChanges = true;
        pauseQueue(
          'Queue paused until the response is saved. Then choose Resume.',
          allSources: true,
        );
        error =
            'Stopped reply could not be saved. Keep this conversation open and try saving again before closing Saathi.';
      }
      return;
    }
    _terminalProblems[session] =
        'Reply stopped before any text arrived. Nothing was resent.';
    if (!await _discardPrepared(source)) {
      _uncertain[session] = source;
      _paused[session] =
          'The held input could not be removed from storage. Try abandoning it or start a new conversation; nothing will be sent again.';
    }
  }

  // Only the drain may bypass public FIFO admission for its captured head.
  Future<_DispatchResult> _dispatch(
    String text, {
    QueuedFollowup? source,
  }) async {
    final session = source?.session ?? current;
    final photos = source?.photos ?? const <ChatPhoto>[];
    if (_disposed ||
        _loadFailed ||
        _quarantinedInputs.contains(session) ||
        loading ||
        changingConnection ||
        busy ||
        _canonicalQueueSaving.contains(session) ||
        _uncertain.containsKey(session) ||
        runPending ||
        organizationBlocked ||
        unsavedChanges ||
        session == null ||
        (text.trim().isEmpty && photos.isEmpty)) {
      return _DispatchResult.notDispatched;
    }
    final found = connections.where((c) => c['id'] == session.connectionId);
    if (found.isEmpty) {
      error =
          'This conversation’s connection is unavailable. Create a new conversation.';
      notifyListeners();
      return _DispatchResult.notDispatched;
    }
    final connection = source?.connection ?? found.single;
    if (photos.isNotEmpty && !_supportsPhotos(connection)) {
      return _DispatchResult.notDispatched;
    }
    final permission = _DispatchPermission(
      source ??
          QueuedFollowup(
            text,
            session,
            connection,
            model: replyModel(session),
            captured: organization.captureInstructions(
              identityOf(session),
              fallback: session.systemPrompt,
            ),
          ),
    );
    _dispatchingSession = session;
    _dispatchRun = null;
    _preparing = permission;
    busy = true;
    _terminalProblems.remove(session);
    error = null;
    pendingText = text;
    notifyListeners();
    var responseCompleted = false;
    var dispatched = false;
    SaathiCore? core;
    try {
      if (connection['type'] == 'hermesGateway') {
        final owner = canonical;
        if (owner == null || !owner.connected || !_bound(permission.source)) {
          return _DispatchResult.notDispatched;
        }
        try {
          await owner.send(text, inputId: permission.source.replyId);
        } catch (_) {
          if (!owner.pending) rethrow;
          // The owner retains the original journal and plain-language recovery.
          // An acknowledgement loss is not a confirmed execution failure.
        }
        if (owner.awaitingSnapshotSave) await refreshCanonical();
        return _DispatchResult.admitted;
      }
      final runResult = await _sendRun(session, connection, text, permission);
      if (runResult != null) return runResult;
      await _savePrepared(permission.source, 'prepared');
      core = await coreFor(connection);
      if (_disposed ||
          permission.revoked ||
          !_bound(permission.source) ||
          _paused.containsKey(session) ||
          _background ||
          _loadFailed ||
          !sessions.contains(session) ||
          !connections.any((c) => identical(c, connection))) {
        return _DispatchResult.notDispatched;
      }
      core.setSystemPrompt(permission.source.captured.instructions);
      final selected = ModelInfo(
        providerId: session.connectionId,
        name: permission.source.model,
        upstreamProvider: session.upstreamProvider,
      );
      core.registerModel(selected);
      core.selectModel(selected.id);
      core.restoreHistory(session.messages);
      await _savePrepared(permission.source, 'dispatched');
      if (_disposed ||
          permission.revoked ||
          !_bound(permission.source) ||
          _background) {
        await _savePrepared(permission.source, 'prepared');
        return _DispatchResult.notDispatched;
      }
      _preparing = null;
      dispatched = true;
      final cancel = Completer<void>();
      _directCancel = cancel;
      _directStreamSession = session;
      _directStreamPreview = null;
      _directStoppedByUser = false;
      notifyListeners();
      final buffer = StringBuffer();
      final previewBuffer = StringBuffer();
      var streamMetadata = const <String, dynamic>{};
      try {
        await for (final chunk in core.streamMessage(
          text,
          cancelTrigger: cancel.future,
        )) {
          if (chunk.metadata.isNotEmpty) {
            streamMetadata = chunk.metadata;
          }
          if (chunk.text.isNotEmpty) {
            buffer.write(chunk.text);
            final remaining = maxStreamPreviewLength - previewBuffer.length;
            if (remaining > 0) {
              previewBuffer.write(
                chunk.text.length <= remaining
                    ? chunk.text
                    : chunk.text.substring(0, remaining),
              );
              _directStreamPreview = previewBuffer.toString();
              notifyListeners();
            }
          }
        }
      } on RequestCancelledException {
        if (_disposed) {
          responseCompleted = true;
          return _DispatchResult.stopped;
        }
        if (_directStoppedByUser) {
          _directStreamPreview = null;
          _directStreamSession = null;
          _directCancel = null;
          _directStoppedByUser = false;
          responseCompleted = true;
          await _completeStoppedDirectReply(
            session,
            input: text,
            partialText: buffer.toString(),
            source: permission.source,
            metadata: streamMetadata,
          );
          return _DispatchResult.stopped;
        }
        rethrow;
      }
      _directStreamPreview = null;
      _directStreamSession = null;
      _directCancel = null;
      _directStoppedByUser = false;
      responseCompleted = true;
      await _completeReply(
        session,
        input: text,
        text: buffer.toString(),
        replyId: permission.source.replyId,
        metadata: streamMetadata,
      );
      return _DispatchResult.completed;
    } on ProviderException catch (e) {
      error = e.message;
      return dispatched
          ? _DispatchResult.dispatchedUnknown
          : _DispatchResult.notDispatched;
    } catch (_) {
      if (runs[session.id] != null && !runs[session.id]!.committed) {
        final op = runs[session.id]!;
        if (op.runId != null && !op.snapshot.terminal) {
          _statusUnavailable(session, op);
        } else if (op.data['attempted'] == true) {
          _syncUnavailable(session, op);
        } else {
          _observationProblems[op.key] =
              'Could not reach the server to send your message. Keep the original connection and try again.';
          _paused[session] =
              'Check your message before resuming queued messages.';
        }
        return _DispatchResult.admitted;
      }
      error =
          'Could not complete or save this response. Check your connection and secure storage.';
      return dispatched
          ? _DispatchResult.dispatchedUnknown
          : _DispatchResult.notDispatched;
    } finally {
      if (identical(_preparing, permission)) _preparing = null;
      if (identical(_dispatchingSession, session)) _dispatchingSession = null;
      if (identical(_directStreamSession, session)) {
        _directStreamSession = null;
        _directStreamPreview = null;
        _directCancel = null;
      }
      _directStoppedByUser = false;
      _dispatchRun = null;
      core?.close();
      busy = false;
      pendingText = null;
      if (dispatched && !responseCompleted) {
        _uncertain[session] = permission.source;
        _paused[session] =
            'Outcome unknown. The last request may have executed. It will not be sent again. Start a new conversation safely, or explicitly abandon this held outbox.';
      }
      if (!_draining &&
          !_uncertain.containsKey(session) &&
          !_outbox.any((item) => identical(item.session, session))) {
        _paused.remove(session);
      }
      if (!_draining && unsavedChanges && runs[session.id] == null) {
        pauseQueue(
          'Queue paused until the response is saved. Then choose Resume.',
          allSources: true,
        );
      }
      notifyListeners();
      _scheduleSelectedQueue();
    }
  }
}
