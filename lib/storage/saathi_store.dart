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
  const PlatformSecrets([this.storage = const FlutterSecureStorage()]);
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

class SaathiStore {
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
      {required String apiKey}) async {
    // Whitelist fields: tokens can never accidentally enter ordinary preferences.
    final safe = <String, dynamic>{
      for (final key in [
        'id',
        'name',
        'url',
        'type',
        'model',
        'systemPrompt',
        'allowInsecureHttp'
      ])
        if (connection.containsKey(key)) key: connection[key]
    };
    final id = safe['id'] as String;
    await secrets.write(id, apiKey);
    final all = _read('saathi.connections.v1')
      ..removeWhere((c) => c['id'] == id);
    all.add(safe);
    if (!await preferences.setString(
        'saathi.connections.v1', jsonEncode(all))) {
      throw StateError('Could not save connection');
    }
  }

  Future<void> saveChats(List<Map<String, dynamic>> chats) async {
    // Persist only displayable conversation data, never arbitrary provider metadata.
    final safe = [
      for (final chat in chats)
        {
          for (final key in ['id', 'connectionId', 'model', 'systemPrompt'])
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
