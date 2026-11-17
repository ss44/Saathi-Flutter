import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Original local/connection identity. Display edits never change either ID.
@immutable
class ConversationIdentity {
  const ConversationIdentity(this.connectionId, this.chatId);
  final String connectionId, chatId;
  String get storageKey => jsonEncode([connectionId, chatId]);
  @override
  bool operator ==(Object other) =>
      other is ConversationIdentity &&
      other.connectionId == connectionId &&
      other.chatId == chatId;
  @override
  int get hashCode => Object.hash(connectionId, chatId);
}

@immutable
class ConversationPresentation {
  const ConversationPresentation(
      {this.displayName = '',
      this.archived = false,
      this.personaId,
      this.completions = const {}});
  final String displayName;
  final bool archived;
  final String? personaId;

  /// Stable authoritative reply identity -> durably seen. ACKs/deltas never enter.
  final Map<String, bool> completions;
  bool get unread => completions.values.any((seen) => !seen);
  List<String> get unreadCompletionIds => [
        for (final e in completions.entries)
          if (!e.value) e.key
      ];
  String title(String fallback) => displayName.isEmpty ? fallback : displayName;
  ConversationPresentation copyWith(
          {String? displayName,
          bool? archived,
          String? personaId,
          bool clearPersona = false,
          Map<String, bool>? completions}) =>
      ConversationPresentation(
          displayName: displayName ?? this.displayName,
          archived: archived ?? this.archived,
          personaId: clearPersona ? null : personaId ?? this.personaId,
          completions: Map.unmodifiable(completions ?? this.completions));
  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        'archived': archived,
        if (personaId != null) 'personaId': personaId,
        'completions': completions
      };
}

/// Separate bounded metadata; no backend configuration, messages or secrets.
/// A false preference write is failure even if the plugin's cache changed.
class OrganizationStorage {
  OrganizationStorage(this.preferences);
  final SharedPreferences preferences;
  static const key = 'saathi.organization.v1';
  String? read() => preferences.getString(key);
  Future<void> write(String value) async {
    final before = preferences.getString(key);
    try {
      if (!await preferences.setString(key, value)) {
        throw StateError('Could not save conversation details');
      }
    } catch (_) {
      // SharedPreferences updates its memory cache BEFORE durability returns.
      // Restore that cache as well as trying compensating disk recovery.
      try {
        if (before == null) {
          await preferences.remove(key);
        } else {
          await preferences.setString(key, before);
        }
      } catch (_) {
        // Caller remains blocked with the exact unsaved candidate for recovery.
      }
      throw StateError('Could not save conversation details');
    }
  }
}

enum PersonaEditPolicy { localInstructions, serverOwned, importedReadOnly }

/// A full per-conversation deduplication ledger, not a retryable disk failure.
/// Keep its reply IDs and isolate this conversation while other chats proceed.
class OrganizationCapacityException implements Exception {
  const OrganizationCapacityException(this.identity);
  final ConversationIdentity identity;
}

/// A reusable assistant role, not a backend workspace, provider or credential.
@immutable
class SharedPersona {
  const SharedPersona(
      {required this.id,
      required this.name,
      required this.instructions,
      this.revision = 1});
  final String id, name, instructions;
  final int revision;
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'instructions': instructions,
        'revision': revision
      };
}

/// Capture this at acceptance, before queuing/awaiting credentials. Never look up
/// mutable persona instructions again when dispatching an accepted input.
@immutable
class CapturedInstructions {
  const CapturedInstructions(this.personaId, this.revision, this.instructions);
  final String? personaId;
  final int revision;
  final String instructions;
}

/// Sole owner of organization metadata. Save failures retain a retryable candidate
/// without committing UI state. Retry never sends, polls or replays any model input.
class ChatOrganization extends ChangeNotifier {
  ChatOrganization(this.storage);
  final OrganizationStorage storage;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Map<String, ConversationPresentation> _entries = {};
  Map<String, SharedPersona> _personas = {};
  Map<String, SharedPersona>? _pendingPersonas;
  List<SharedPersona> get personas => List.unmodifiable(_personas.values);
  Map<String, ConversationPresentation>? _pending;
  bool saving = false;
  bool loaded = false;
  bool _pendingIsEdit = false;
  void Function()? _pendingValidation;
  bool get hasUnsavedChanges => _pending != null;

  /// Explicit Cancel may discard a failed metadata edit, never a failed reply or
  /// seen-marker write. Call only from the dialog which owns that failed edit.
  void discardPendingEdit() {
    if (saving || !_pendingIsEdit) {
      throw StateError('Pending reply data cannot be discarded here');
    }
    _pending = null;
    _pendingPersonas = null;
    _pendingIsEdit = false;
    _pendingValidation = null;
    error = null;
    notifyListeners();
  }

  String? error;
  ConversationPresentation entry(ConversationIdentity identity) =>
      _entries[identity.storageKey] ?? const ConversationPresentation();
  Map<String, dynamic> _json(Map<String, ConversationPresentation> chats,
          Map<String, SharedPersona> personas) =>
      {
        'schema': 1,
        'chats': {for (final e in chats.entries) e.key: e.value.toJson()},
        'personas': [for (final p in personas.values) p.toJson()]
      };
  Map<String, dynamic> toJson() => _json(_entries, _personas);
  Future<void> load() async {
    if (_disposed || saving || hasUnsavedChanges) {
      throw StateError('Recover unsaved details first');
    }
    final raw = storage.read();
    final next = <String, ConversationPresentation>{};
    final personas = <String, SharedPersona>{};
    if (raw != null) {
      if (raw.length > 2 * 1024 * 1024) {
        throw const FormatException('Conversation details too large');
      }
      final json = jsonDecode(raw);
      if (json is! Map || json['schema'] != 1 || json['chats'] is! Map) {
        throw const FormatException('Invalid conversation details');
      }
      final chats = json['chats'] as Map;
      if (chats.length > 1000) {
        throw const FormatException('Too many conversation details');
      }
      for (final e in chats.entries) {
        final ids = jsonDecode(e.key as String);
        if (ids is! List ||
            ids.length != 2 ||
            ids.any((v) => v is! String || v.isEmpty || v.length > 256)) {
          throw const FormatException('Invalid conversation identity');
        }
        final data = e.value;
        if (data is! Map) {
          throw const FormatException('Invalid conversation details');
        }
        final name = data['displayName'];
        final archived = data['archived'];
        final persona = data['personaId'];
        final completions = data['completions'];
        if (name is! String ||
            name.length > 120 ||
            archived is! bool ||
            (persona != null &&
                (persona is! String ||
                    persona.isEmpty ||
                    persona.length > 256)) ||
            completions is! Map ||
            completions.length > 512 ||
            completions.entries.any((e) =>
                e.key is! String ||
                (e.key as String).isEmpty ||
                (e.key as String).length > 256 ||
                e.value is! bool)) {
          throw const FormatException('Invalid conversation details');
        }
        next[e.key as String] = ConversationPresentation(
            displayName: name,
            archived: archived,
            personaId: persona as String?,
            completions: Map.unmodifiable(Map<String, bool>.from(completions)));
      }
      final savedPersonas = json['personas'] ?? [];
      if (savedPersonas is! List || savedPersonas.length > 100) {
        throw const FormatException('Invalid personas');
      }
      for (final p in savedPersonas) {
        if (p is! Map ||
            p['id'] is! String ||
            p['name'] is! String ||
            p['instructions'] is! String ||
            p['revision'] is! int) {
          throw const FormatException('Invalid persona');
        }
        final persona = SharedPersona(
            id: p['id'],
            name: p['name'],
            instructions: p['instructions'],
            revision: p['revision']);
        _validatePersona(persona);
        if (personas.containsKey(persona.id)) {
          throw const FormatException('Duplicate persona');
        }
        personas[persona.id] = persona;
      }
      if (next.values.any(
          (e) => e.personaId != null && !personas.containsKey(e.personaId))) {
        throw const FormatException('Missing persona');
      }
    }
    _entries = next;
    _personas = personas;
    loaded = true;
    notifyListeners();
  }

  void _checkIdentity(ConversationIdentity key) {
    if ([key.connectionId, key.chatId]
        .any((s) => s.isEmpty || s.length > 256)) {
      throw ArgumentError('Invalid conversation identity');
    }
  }

  Future<void> _save(Map<String, ConversationPresentation> next,
      {Map<String, SharedPersona>? personas,
      bool edit = true,
      void Function()? validate}) async {
    if (_disposed || !loaded || saving || hasUnsavedChanges) {
      throw StateError('Save or recover conversation details first');
    }
    if (next.length > 1000) {
      throw StateError('Conversation details limit reached');
    }
    _pendingIsEdit = edit;
    _pendingValidation = validate;
    _pending = next;
    _pendingPersonas = personas ?? _personas;
    await retrySave();
  }

  Future<void> retrySave() async {
    if (_disposed || saving) {
      throw StateError(
          'Conversation details are unavailable or already saving');
    }
    if (_pending == null) return;
    saving = true;
    error = null;
    notifyListeners();
    try {
      _pendingValidation?.call();
      final value = jsonEncode(_json(_pending!, _pendingPersonas!));
      if (value.length > 2 * 1024 * 1024) {
        throw StateError('Conversation details limit reached');
      }
      await storage.write(value);
      _entries = _pending!;
      _personas = _pendingPersonas!;
      _pending = null;
      _pendingPersonas = null;
      _pendingValidation = null;
    } catch (_) {
      error =
          'Conversation details were not saved. Try saving again; no message will be sent.';
      rethrow;
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  CapturedInstructions captureInstructions(ConversationIdentity key,
      {required String fallback}) {
    final persona = _personas[entry(key).personaId];
    return CapturedInstructions(
        persona?.id, persona?.revision ?? 0, persona?.instructions ?? fallback);
  }

  List<ConversationIdentity> affectedChats(String personaId) => [
        for (final e in _entries.entries)
          if (e.value.personaId == personaId)
            ConversationIdentity((jsonDecode(e.key) as List)[0] as String,
                (jsonDecode(e.key) as List)[1] as String)
      ];
  void _validatePersona(SharedPersona persona) {
    if (persona.id.isEmpty ||
        persona.id.length > 256 ||
        persona.name.trim().isEmpty ||
        persona.name.length > 80 ||
        persona.instructions.length > 16000 ||
        persona.revision < 1 ||
        persona.revision > 2147483647) {
      throw const FormatException('Invalid persona');
    }
  }

  /// Recheck every affected chat at Save. Caller must include queued, in-flight,
  /// uncertain and imported/native-owned restrictions, not only selected busy.
  Future<void> savePersona(SharedPersona persona,
      {required String? Function(ConversationIdentity) canEdit}) async {
    _validatePersona(persona);
    if (!_personas.containsKey(persona.id) && _personas.length >= 100) {
      throw StateError('Persona limit reached');
    }
    for (final key in affectedChats(persona.id)) {
      final reason = canEdit(key);
      if (reason != null) throw StateError(reason);
    }
    final previous = _personas[persona.id];
    final next = SharedPersona(
        id: persona.id,
        name: persona.name.trim(),
        instructions: persona.instructions,
        revision: previous == null ? 1 : previous.revision + 1);
    _validatePersona(next);
    await _save({..._entries}, personas: {..._personas, persona.id: next},
        validate: () {
      for (final key in affectedChats(persona.id)) {
        final reason = canEdit(key);
        if (reason != null) throw StateError(reason);
      }
    });
  }

  Future<void> setArchived(ConversationIdentity key, bool archived) async {
    _checkIdentity(key);
    await _save(
        {..._entries, key.storageKey: entry(key).copyWith(archived: archived)});
  }

  /// Rename is display-only. Persona changes are local-only until a verified
  /// native mutation contract exists; no endpoint or transcript replay is used.
  Future<void> edit(ConversationIdentity key,
      {required String displayName,
      required String? personaId,
      required PersonaEditPolicy policy,
      required String? pendingReason,
      String? Function()? revalidatePersonaChange}) async {
    _checkIdentity(key);
    if (displayName.length > 120) throw ArgumentError('Name is too long');
    final before = entry(key);
    if (personaId != before.personaId) {
      if (policy != PersonaEditPolicy.localInstructions) {
        throw StateError(
            'This server does not expose verified persona editing. Start a separate conversation; history is not copied.');
      }
      if (pendingReason != null) throw StateError(pendingReason);
      if (personaId != null && !_personas.containsKey(personaId)) {
        throw StateError('Persona no longer exists');
      }
    }
    await _save({
      ..._entries,
      key.storageKey: before.copyWith(
          displayName: displayName.trim(),
          personaId: personaId,
          clearPersona: personaId == null)
    },
        validate: personaId == before.personaId
            ? null
            : () {
                final reason = revalidatePersonaChange?.call();
                if (reason != null) throw StateError(reason);
              });
  }

  Future<void> recordCompletion(
      ConversationIdentity key, String replyId) async {
    _checkIdentity(key);
    if (replyId.isEmpty || replyId.length > 256) {
      throw ArgumentError('Invalid reply identity');
    }
    final before = entry(key);
    if (before.completions.containsKey(replyId)) return;
    // Never silently evict a dedupe marker and turn replay into a new reply.
    if (before.completions.length == 512) {
      throw OrganizationCapacityException(key);
    }
    await _save({
      ..._entries,
      key.storageKey:
          before.copyWith(completions: {...before.completions, replyId: false})
    }, edit: false);
  }

  /// Called ONLY by the foreground reply visibility sentinel, never by navigation.
  Future<void> markReplyVisible(
      ConversationIdentity key, String replyId) async {
    final before = entry(key);
    if (!before.completions.containsKey(replyId)) {
      throw StateError(
          'Record the authoritative completion before acknowledging visibility');
    }
    if (before.completions[replyId] != false) return;
    await _save({
      ..._entries,
      key.storageKey:
          before.copyWith(completions: {...before.completions, replyId: true})
    }, edit: false);
  }
}
