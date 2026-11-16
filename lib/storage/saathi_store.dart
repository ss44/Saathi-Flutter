import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SecretStore {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

class PlatformSecrets implements SecretStore {
  final FlutterSecureStorage storage;
  // Standalone macOS apps do not share keys with another app and must not need
  // a machine-specific provisioning profile. The legacy Keychain stays secure;
  // this macOS-only option has no effect on Android/iOS/Windows/Linux storage.
  const PlatformSecrets(
      [this.storage = const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false))]);
  @override
  Future<String?> read(String id) => storage.read(key: 'saathi.connection.$id');
  @override
  Future<void> write(String id, String value) =>
      storage.write(key: 'saathi.connection.$id', value: value);
  @override
  Future<void> delete(String id) =>
      storage.delete(key: 'saathi.connection.$id');
}

class MemorySecrets implements SecretStore {
  final Map<String, String> _values = {};
  @override
  Future<String?> read(String id) async => _values[id];
  @override
  Future<void> write(String id, String value) async {
    _values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    _values.remove(id);
  }
}

class StoredState {
  final List<Map<String, dynamic>> connections;
  final List<Map<String, dynamic>> chats;
  StoredState(this.connections, this.chats);
}

class StorageRecoveryException implements Exception {
  const StorageRecoveryException();
}

class SaathiStore {
  bool _mutating = false;
  Future<void> _exclusive(Future<void> Function() operation) async {
    if (_mutating) throw StateError('Connection write already in progress');
    _mutating = true;
    try {
      await operation();
    } finally {
      _mutating = false;
    }
  }

  final SharedPreferences preferences;
  final SecretStore secrets;
  SaathiStore({required this.preferences, required this.secrets});
  static Future<SaathiStore> open() async => SaathiStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: const PlatformSecrets());
  List<Map<String, dynamic>> _read(String key) {
    final raw = preferences.getString(key);
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('Invalid saved data');
    return decoded
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  Future<StoredState> load() async =>
      StoredState(_read('saathi.connections.v1'), _read('saathi.chats.v1'));
  Future<void> saveConnection(Map<String, dynamic> connection,
          {required String apiKey}) =>
      _exclusive(() async {
        // Whitelist fields: tokens can never accidentally enter ordinary preferences.
        final safe = <String, dynamic>{
          for (final key in [
            'id',
            'name',
            'url',
            'type',
            'model',
            'systemPrompt',
            'authorityEpoch',
            'allowInsecureHttp'
          ])
            if (connection.containsKey(key)) key: connection[key]
        };
        final id = safe['id'] as String;
        final before = _read('saathi.connections.v1');
        final oldKey = await secrets.read(id);
        try {
          await secrets.write(id, apiKey);
          final all = _read('saathi.connections.v1')
            ..removeWhere((c) => c['id'] == id);
          all.add(safe);
          if (!await preferences.setString(
              'saathi.connections.v1', jsonEncode(all))) {
            throw StateError('Could not save connection');
          }
        } catch (_) {
          await _restore(before, id, id, oldKey);
          rethrow;
        }
      });

  // Cross-store writes are compensating, not atomic. A failed compensation is
  // reported as failure too; callers must retain the visible connection.
  Future<void> changeConnection(String id,
          {Map<String, dynamic>? replacement, String? apiKey}) =>
      _exclusive(() async {
        const pref = 'saathi.connections.v1';
        final before = _read(pref);
        if (!before.any((c) => c['id'] == id)) {
          throw StateError('Connection no longer exists');
        }
        final oldKey = await secrets.read(id);
        final newId = replacement?['id'] as String? ?? id;
        final safe = replacement == null
            ? null
            : <String, dynamic>{
                for (final key in [
                  'id',
                  'name',
                  'url',
                  'type',
                  'model',
                  'systemPrompt',
                  'authorityEpoch',
                  'allowInsecureHttp'
                ])
                  if (replacement.containsKey(key) ||
                      before.singleWhere((c) => c['id'] == id).containsKey(key))
                    key: replacement.containsKey(key)
                        ? replacement[key]
                        : before.singleWhere((c) => c['id'] == id)[key],
              };
        final after = [
          for (final c in before)
            if (c['id'] != id) c,
          if (safe != null) safe
        ];
        try {
          if (safe != null) {
            final nextKey = apiKey ?? oldKey;
            if (nextKey == null || nextKey.isEmpty) {
              await secrets.delete(newId);
            } else {
              await secrets.write(newId, nextKey);
            }
          }
          if (safe == null || newId != id) await secrets.delete(id);
          if (!await preferences.setString(pref, jsonEncode(after))) {
            throw StateError('Connection metadata write failed');
          }
        } catch (_) {
          await _restore(before, id, newId, oldKey);
          throw StateError(
              'Connection could not be saved; previous data restored');
        }
      });

  Future<void> _restore(List<Map<String, dynamic>> before, String id,
      String newId, String? oldKey) async {
    bool recovered = true;
    try {
      if (!await preferences.setString(
          'saathi.connections.v1', jsonEncode(before))) {
        recovered = false;
      }
    } catch (_) {
      recovered = false;
    }
    if (newId != id) {
      try {
        await secrets.delete(newId);
      } catch (_) {
        recovered = false;
      }
    }
    try {
      if (oldKey == null) {
        await secrets.delete(id);
      } else {
        await secrets.write(id, oldKey);
      }
    } catch (_) {
      recovered = false;
    }
    if (!recovered) throw const StorageRecoveryException();
  }

  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    // Persist only displayable conversation data, never arbitrary provider metadata.
    final safe = [
      for (final chat in chats)
        {
          for (final key in [
            'id',
            'connectionId',
            'model',
            'upstreamProvider',
            'systemPrompt'
          ])
            if (chat.containsKey(key)) key: chat[key],
          'messages': [
            for (final message in (chat['messages'] as List? ?? []))
              {
                for (final key in ['id', 'role', 'content'])
                  if ((message as Map).containsKey(key)) key: message[key],
              }
          ],
        }
    ];
    if (!await preferences.setString('saathi.chats.v1', jsonEncode(safe))) {
      throw StateError('Could not save chats');
    }
  }
}
