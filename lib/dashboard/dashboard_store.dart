import 'dart:convert';
import 'dart:math';
import '../auth/hermes_dashboard_auth.dart';
import '../gateway/hermes_gateway.dart';
import '../storage/saathi_store.dart';

class DashboardLoginCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void Function()? _close;
  void cancel() {
    _cancelled = true;
    _close?.call();
  }
}

class DashboardConnection {
  const DashboardConnection(
      {required this.id, required this.name, required this.baseUrl});
  final String id, name, baseUrl;
  Map<String, String> toJson() => {'id': id, 'name': name, 'baseUrl': baseUrl};
}

/// Dashboard metadata and cookie sessions never enter provider/chat schemas.
class DashboardStore {
  DashboardStore(this.storage);
  final SaathiStore storage;
  static const preferencesKey = 'saathi.dashboard.connections.v1';
  static String secretId(String id) => 'dashboard.session.v1.$id';
  final _brokers = <String, HermesDashboardAuth>{};
  final _gateways = <HermesGatewayClient>{};
  final _pending = <HermesDashboardAuth>{};
  final _pendingIds = <String>{};
  Future<void> _metadataTail = Future.value();
  Future<void> _metadata(Future<void> Function() action) {
    final next = _metadataTail.then((_) => action());
    _metadataTail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  bool _closed = false;
  final _secretTails = <String, Future<void>>{};
  final _removed = <String>{};
  Future<void> _secret(String id, Future<void> Function() action) {
    final next =
        (_secretTails[id] ?? Future<void>.value()).then((_) => action());
    _secretTails[id] = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<List<DashboardConnection>> load() async {
    final raw = storage.preferences.getString(preferencesKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((r) => DashboardConnection(
            id: r['id'] as String,
            name: r['name'] as String,
            baseUrl: r['baseUrl'] as String))
        .where((e) => !_removed.contains(e.id))
        .toList();
  }

  Future<void> _save(List<DashboardConnection> entries) async {
    if (!await storage.preferences.setString(
        preferencesKey, jsonEncode(entries.map((e) => e.toJson()).toList()))) {
      throw const AuthException('Could not save dashboard securely.');
    }
  }

  HermesDashboardAuth _broker(DashboardConnection entry, {String? saved}) =>
      HermesDashboardAuth(
          baseUrl: Uri.parse(entry.baseUrl),
          savedSession: saved,
          onSessionChanged: (state) async {
            if (_closed) throw const AuthException('Dashboard closed.');
            await _secret(entry.id, () async {
              if (_removed.contains(entry.id)) return;
              if (state == null) {
                await storage.secrets.delete(secretId(entry.id));
              } else {
                await storage.secrets.write(secretId(entry.id), state);
              }
            });
          });
  Future<DashboardConnection> signIn(
      {required String name,
      required String baseUrl,
      required String username,
      required String password,
      DashboardLoginCancellation? cancellation}) async {
    if (_closed) throw const AuthException('Dashboard closed.');
    final id = List.generate(
            24,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final candidate = DashboardConnection(id: id, name: name, baseUrl: baseUrl);
    final broker = _broker(candidate);
    _pending.add(broker);
    _pendingIds.add(id);
    cancellation?._close = () {
      _removed.add(id);
      broker.close();
    };
    bool cancelled() => _closed || (cancellation?._cancelled ?? false);
    final entry = DashboardConnection(
        id: id, name: name, baseUrl: broker.baseUrl.toString());
    try {
      if (cancelled()) throw const AuthException('Login cancelled.');
      await broker.signIn(username, password);
      await _metadata(() async {
        if (cancelled()) throw const AuthException('Login cancelled.');
        await _save([...await load(), entry]);
        if (cancelled()) throw const AuthException('Login cancelled.');
      });
      if (cancelled()) throw const AuthException('Login cancelled.');
      _brokers[id] = broker;
      return entry;
    } catch (_) {
      broker.close();
      try {
        _removed.add(id);
        await _secret(id, () => storage.secrets.delete(secretId(id)));
        await _metadata(() async {
          await _save((await load())..removeWhere((e) => e.id == id));
        });
      } catch (_) {/* Report failure, never success. */}
      throw const AuthException('Could not sign in and save securely.');
    } finally {
      _pending.remove(broker);
      _pendingIds.remove(id);
      cancellation?._close = null;
    }
  }

  Future<DashboardIdentity> open(DashboardConnection entry) async {
    if (_closed || _removed.contains(entry.id)) {
      throw const AuthException('Dashboard closed or removed.');
    }
    var broker = _brokers[entry.id];
    try {
      if (broker == null) {
        final saved = await storage.secrets.read(secretId(entry.id));
        if (_closed || _removed.contains(entry.id)) {
          throw const AuthException('Dashboard closed or removed.');
        }
        if (saved == null) throw const AuthException('Sign in again.');
        broker = _broker(entry, saved: saved);
        _brokers[entry.id] = broker;
      }
      final identity = await broker.currentIdentity();
      if (_closed || _removed.contains(entry.id)) {
        throw const AuthException('Dashboard closed or removed.');
      }
      return identity;
    } catch (_) {
      _brokers.remove(entry.id)?.close();
      throw const AuthException(
          'Could not validate saved dashboard session. Remove it and sign in again.');
    }
  }

  Future<HermesGatewayClient> connect(DashboardConnection entry) async {
    await open(entry);
    if (_closed || _removed.contains(entry.id)) {
      throw const AuthException('Dashboard closed or removed.');
    }
    final broker = _brokers[entry.id]!;
    final gateway = HermesGatewayClient(grantProvider: broker.grant);
    _gateways.add(gateway);
    try {
      await gateway.connect();
      if (_closed || _removed.contains(entry.id)) {
        throw const AuthException('Dashboard closed or removed.');
      }
      return gateway;
    } catch (_) {
      _gateways.remove(gateway);
      await gateway.dispose();
      rethrow;
    }
  }

  Future<void> remove(DashboardConnection entry) async {
    // Local deletion is mandatory even when the server cannot be reached.
    _removed.add(entry.id);
    final broker = _brokers.remove(entry.id);
    for (final gateway in _gateways.toList()) {
      await gateway.dispose();
    }
    _gateways.clear();
    try {
      await broker?.signOut();
    } catch (_) {/* Network logout is best effort. */} finally {
      broker?.close();
    }
    try {
      await _secret(entry.id, () => storage.secrets.delete(secretId(entry.id)));
      await _metadata(() async {
        await _save((await load())..removeWhere((e) => e.id == entry.id));
      });
    } catch (_) {
      throw const AuthException('Could not remove saved dashboard securely.');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _removed.addAll(_pendingIds);
    for (final gateway in _gateways) {
      gateway.dispose();
    }
    _gateways.clear();
    for (final broker in _pending) {
      broker.close();
    }
    _pending.clear();
    for (final broker in _brokers.values) {
      broker.close();
    }
    _brokers.clear();
  }
}
