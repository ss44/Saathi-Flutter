import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../gateway/hermes_gateway.dart';

abstract interface class DashboardSession {
  Future<DashboardIdentity> signIn(String username, String password);
  Future<DashboardIdentity> currentIdentity();
  Future<GatewayGrant> grant();
  Future<void> signOut();
  void close();
}

class DashboardIdentity {
  const DashboardIdentity(
      {required this.userId,
      required this.provider,
      required this.displayName,
      this.expiresAt});
  final String userId, provider, displayName;
  final DateTime? expiresAt;
}

class AuthException implements Exception {
  const AuthException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'AuthException: $message';
}

/// Owns a private cookie session. The callback MUST write to secure storage.
class HermesDashboardAuth implements DashboardSession {
  HermesDashboardAuth(
      {required Uri baseUrl,
      String? savedSession,
      required this.onSessionChanged,
      HttpClient? client})
      : baseUrl = _validate(baseUrl),
        _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
    if (savedSession != null) _restore(savedSession);
  }
  final Uri baseUrl;
  final Future<void> Function(String? secureState) onSessionChanged;
  final HttpClient _client;
  final List<_StoredCookie> _cookies = [];
  Future<void> _tail = Future.value();
  bool _closed = false, _verified = false;
  static const _timeout = Duration(seconds: 15);
  static Uri _validate(Uri u) {
    final ip = InternetAddress.tryParse(u.host);
    if (!u.hasAuthority ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment ||
        !(u.scheme == 'https' ||
            (u.scheme == 'http' && ip != null && ip.isLoopback)) ||
        u.pathSegments.any((s) =>
            s == '.' || s == '..' || s.contains('/') || s.contains('\\'))) {
      throw const AuthException('Invalid dashboard URL.');
    }
    return u.replace(path: '${u.path.replaceFirst(RegExp(r'/+$'), '')}/');
  }

  Uri _url(String path) => baseUrl.resolve(path);
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) async {
      if (_closed) throw const AuthException('Session is closed.');
      try {
        return await action();
      } on AuthException {
        rethrow;
      } catch (_) {
        throw const AuthException('Dashboard authentication failed.');
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _prune() => _cookies.removeWhere(
      (c) => c.expires != null && !c.expires!.isAfter(DateTime.now().toUtc()));
  Future<void> _persist() async {
    _prune();
    if (!_closed) {
      await onSessionChanged(_cookies.isEmpty
          ? null
          : jsonEncode({
              'version': 1,
              'base': baseUrl.toString(),
              'cookies': _cookies.map((c) => c.json()).toList()
            }));
    }
  }

  void _restore(String state) {
    try {
      if (state.length > 65536) throw const FormatException();
      final data = jsonDecode(state) as Map;
      if (data['version'] != 1 || data['base'] != baseUrl.toString()) {
        throw const FormatException();
      }
      final rows = data['cookies'] as List;
      if (rows.length > 64) throw const FormatException();
      for (final row in rows) {
        final c = Cookie(row['name'] as String, row['value'] as String)
          ..domain = row['domain'] as String?
          ..path = row['path'] as String
          ..secure = row['secure'] as bool
          ..httpOnly = row['httpOnly'] as bool;
        final expires = row['expires'] == null
            ? null
            : DateTime.parse(row['expires'] as String).toUtc();
        _check(c);
        _cookies.add(_StoredCookie(c, expires));
      }
      _prune();
      _verified = _cookies.isNotEmpty;
    } catch (_) {
      _cookies.clear();
      throw const AuthException('Invalid saved dashboard session.');
    }
  }

  void _check(Cookie c) {
    final domain = c.domain?.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
    if ((domain != null && domain != baseUrl.host.toLowerCase()) ||
        c.path == null ||
        !c.path!.startsWith('/') ||
        (c.secure && baseUrl.scheme != 'https') ||
        (c.name.startsWith('__Secure-') && !c.secure) ||
        (c.name.startsWith('__Host-') &&
            (!c.secure || c.domain != null || c.path != '/'))) {
      throw const AuthException('Invalid dashboard session cookie.');
    }
    final mount = baseUrl.path.replaceFirst(RegExp(r'/$'), '');
    if (c.path != '/' && c.path != mount && !c.path!.startsWith('$mount/')) {
      throw const AuthException('Invalid dashboard session cookie.');
    }
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, dynamic>? body, bool logout = false}) async {
    HttpClientRequest? request;
    var cancelled = false;
    var persistCookies = false;
    Future<Map<String, dynamic>> run() async {
      final r = await _client.openUrl(method, _url(path));
      request = r;
      if (cancelled || _closed) {
        r.abort();
        throw const AuthException('Session is closed.');
      }
      r.followRedirects = false;
      r.maxRedirects = 0;
      r.headers.set(HttpHeaders.acceptHeader, 'application/json');
      // Exact listener origin; no forwarded headers or browser credential substitution.
      r.headers.set('Origin', baseUrl.origin);
      _prune();
      final target = _url(path).path;
      final matches = _cookies
          .where((s) =>
              target == s.cookie.path ||
              target.startsWith(s.cookie.path!.endsWith('/')
                  ? s.cookie.path!
                  : '${s.cookie.path}/'))
          .toList()
        ..sort(
            (a, b) => b.cookie.path!.length.compareTo(a.cookie.path!.length));
      r.cookies.addAll(matches.map((s) => s.cookie));
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        if (bytes.length > 16384) {
          throw const AuthException('Credentials exceed request limit.');
        }
        r.headers.contentType = ContentType.json;
        r.add(bytes);
      }
      final response = await r.close();
      if (_closed || cancelled) throw const AuthException('Session is closed.');
      if (response.statusCode >= 300 && response.statusCode < 400) {
        if (logout && response.statusCode == 302) {
          r.abort();
          return {};
        }
        r.abort();
        throw AuthException('Dashboard redirects are not allowed.',
            statusCode: response.statusCode);
      }
      if (response.cookies.length > 64) {
        throw const AuthException('Invalid dashboard session.');
      }
      final updates = <_StoredCookie>[];
      for (final c in response.cookies) {
        c.path ??=
            _url(path).path.substring(0, _url(path).path.lastIndexOf('/') + 1);
        _check(c);
        updates.add(_StoredCookie(
            c,
            c.maxAge != null
                ? DateTime.now().toUtc().add(Duration(seconds: c.maxAge!))
                : c.expires?.toUtc()));
      }
      final next = [..._cookies];
      for (final c in updates) {
        next.removeWhere((s) =>
            s.cookie.name == c.cookie.name && s.cookie.path == c.cookie.path);
        next.add(c);
      }
      next.removeWhere((c) =>
          c.expires != null && !c.expires!.isAfter(DateTime.now().toUtc()));
      final state = jsonEncode({
        'version': 1,
        'base': baseUrl.toString(),
        'cookies': next.map((c) => c.json()).toList()
      });
      if (next.length > 64 || state.length > 65536) {
        throw const AuthException('Invalid dashboard session.');
      }
      _cookies
        ..clear()
        ..addAll(next);
      persistCookies = _verified && updates.isNotEmpty;
      if (response.statusCode != 200) {
        r.abort();
        throw AuthException('Dashboard authentication failed.',
            statusCode: response.statusCode);
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (_closed || cancelled || bytes.length + chunk.length > 65536) {
          r.abort();
          throw const AuthException('Invalid dashboard response.');
        }
        bytes.addAll(chunk);
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }

    try {
      return await run().timeout(_timeout, onTimeout: () {
        cancelled = true;
        request?.abort();
        throw const AuthException('Dashboard request timed out.');
      });
    } catch (_) {
      cancelled = true;
      request?.abort();
      rethrow;
    } finally {
      // Secure writes are not cancellable. Keep them inside the serial operation,
      // but outside the HTTP deadline so logout cannot overtake a stale write.
      if (persistCookies) await _persist();
    }
  }

  @override
  Future<DashboardIdentity> signIn(String username, String password) =>
      _serial(() async {
        _verified = false;
        _cookies.clear();
        try {
          final providers = await _request('GET', 'api/auth/providers');
          if (!(providers['providers'] as List).any(
              (p) => p['name'] == 'basic' && p['supports_password'] == true)) {
            throw const AuthException(
                'Username/password sign-in is unavailable.');
          }
          final result = await _request('POST', 'auth/password-login', body: {
            'provider': 'basic',
            'username': username,
            'password': password,
            'next': '/'
          });
          if (result['ok'] != true || _cookies.isEmpty) {
            throw const AuthException('Dashboard sign-in failed.');
          }
          final identity = await _identity();
          _verified = true;
          await _persist();
          return identity;
        } catch (_) {
          _cookies.clear();
          _verified = false;
          await _persist();
          rethrow;
        }
      });
  Future<DashboardIdentity> _identity() async {
    final me = await _request('GET', 'api/auth/me');
    if (me['user_id'] is! String ||
        (me['user_id'] as String).isEmpty ||
        me['provider'] != 'basic' ||
        me['display_name'] is! String) {
      throw const AuthException('Invalid dashboard identity.');
    }
    return DashboardIdentity(
        userId: me['user_id'],
        provider: me['provider'],
        displayName: me['display_name'],
        expiresAt: me['expires_at'] is num && me['expires_at'] > 0
            ? DateTime.fromMillisecondsSinceEpoch(
                ((me['expires_at'] as num) * 1000).round(),
                isUtc: true)
            : null);
  }

  @override
  Future<DashboardIdentity> currentIdentity() => _serial(_identity);
  @override
  Future<GatewayGrant> grant() => _serial(() async {
        final data = await _request('POST', 'api/auth/ws-ticket');
        final ticket = data['ticket'];
        if (ticket is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,4096}$').hasMatch(ticket) ||
            data['ttl_seconds'] != 30) {
          throw const AuthException('Invalid gateway ticket.');
        }
        return GatewayGrant(
            url: _url('api/ws')
                .replace(scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws'),
            protocols: ['hermes-gateway-v1', 'hermes-gateway-ticket.$ticket']);
      });
  @override
  Future<void> signOut() => _serial(() async {
        try {
          await _request('POST', 'auth/logout', logout: true);
        } finally {
          _cookies.clear();
          _verified = false;
          await _persist();
        }
      });
  @override
  void close() {
    _closed = true;
    _cookies.clear();
    _client.close(force: true);
  }
}

class _StoredCookie {
  _StoredCookie(this.cookie, this.expires);
  final Cookie cookie;
  final DateTime? expires;
  Map<String, dynamic> json() => {
        'name': cookie.name,
        'value': cookie.value,
        'domain': cookie.domain,
        'path': cookie.path,
        'secure': cookie.secure,
        'httpOnly': cookie.httpOnly,
        'expires': expires?.toIso8601String()
      };
}
