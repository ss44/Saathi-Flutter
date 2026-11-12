import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/auth/hermes_dashboard_auth.dart';

void main() {
  late HttpServer server;
  late HermesDashboardAuth auth;
  late List<String?> saved;
  late List<String> paths;
  var status = 200;
  var provider = true;
  var rotate = false;
  var tickets = 0;
  var cookieHeader = '';
  var cookies = <String>[];
  setUp(() async {
    status = 200;
    provider = true;
    rotate = false;
    tickets = 0;
    cookies = [
      'sid_gateway=initial; Path=/m; Max-Age=60',
      'binding_gateway=bound; Path=/m; Expires=Wed, 01 Jan 2031 00:00:00 GMT'
    ];
    saved = [];
    paths = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      paths.add(r.uri.path);
      expect(r.headers.value('authorization'), isNull);
      expect(r.headers.value('origin'), 'http://127.0.0.1:${server.port}');
      cookieHeader = r.headers.value('cookie') ?? '';
      final response = r.response;
      response.headers.contentType = ContentType.json;
      if (r.uri.path.endsWith('/providers')) {
        response.write(jsonEncode({
          'providers': provider
              ? [
                  {'name': 'basic', 'supports_password': true}
                ]
              : []
        }));
      } else if (r.uri.path.endsWith('/password-login')) {
        await r.drain<void>();
        response.statusCode = status;
        if (status == 302) {
          response.headers.set('location', 'http://elsewhere.invalid/steal');
        }
        for (final c in cookies) {
          response.headers.add('set-cookie', c);
        }
        response.write('{"ok":true,"next":"/"}');
      } else if (r.uri.path.endsWith('/me')) {
        if (rotate) {
          response.headers
              .add('set-cookie', 'sid_gateway=rotated; Path=/m; Max-Age=30');
          response.headers
              .add('set-cookie', 'binding_gateway=; Path=/m; Max-Age=0');
        }
        response
            .write('{"user_id":"u","provider":"basic","display_name":"User"}');
      } else if (r.uri.path.endsWith('/ws-ticket')) {
        response.write(
            jsonEncode({'ticket': 'ticket_${++tickets}', 'ttl_seconds': 30}));
      } else if (r.uri.path.endsWith('/logout')) {
        response.statusCode = 302;
        response.headers.set('location', '/m/login');
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });
    auth = HermesDashboardAuth(
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}/m'),
        onSessionChanged: (s) async {
          saved.add(s);
        });
  });
  tearDown(() async {
    auth.close();
    await server.close(force: true);
  });
  test('provider unavailable never submits credentials or probes API server',
      () async {
    provider = false;
    await expectLater(
        auth.signIn('u', 'secret'), throwsA(isA<AuthException>()));
    expect(paths, ['/m/api/auth/providers']);
  });
  test('401 and 429 are generic without response or password echo', () async {
    for (final s in [401, 429]) {
      status = s;
      await expectLater(
          auth.signIn('u', 'secret'),
          throwsA(isA<AuthException>()
              .having((e) => e.statusCode, 'status', s)
              .having(
                  (e) => e.toString(), 'generic', isNot(contains('secret')))));
      expect(saved.last, isNull);
    }
  });
  test('rejects credential redirects without following them', () async {
    status = 302;
    await expectLater(auth.signIn('u', 'p'), throwsA(isA<AuthException>()));
    expect(paths.length, 2);
  });
  test(
      'multiple Expires cookies persist and rotation deletes without resurrection',
      () async {
    await auth.signIn('u', 'p');
    expect((jsonDecode(saved.last!)['cookies'] as List).length, 2);
    rotate = true;
    await auth.currentIdentity();
    expect(saved.last, contains('rotated'));
    expect(saved.last, isNot(contains('bound')));
    final restored = HermesDashboardAuth(
        baseUrl: auth.baseUrl,
        savedSession: saved.last,
        onSessionChanged: (s) async {});
    try {
      rotate = false;
      await restored.currentIdentity();
      expect(cookieHeader, contains('rotated'));
      expect(cookieHeader, isNot(contains('bound')));
    } finally {
      restored.close();
    }
  });
  test('fresh grants preserve mount and do not persist tickets', () async {
    await auth.signIn('u', 'p');
    final grants = await Future.wait([auth.grant(), auth.grant()]);
    expect(grants.first.url.path, '/m/api/ws');
    expect(grants.first.protocols,
        ['hermes-gateway-v1', 'hermes-gateway-ticket.ticket_1']);
    expect(grants.last.protocols.last, 'hermes-gateway-ticket.ticket_2');
    expect(saved.last, isNot(contains('ticket_')));
  });
  test('absolute Max-Age expiry cannot restart on restore', () async {
    await auth.signIn('u', 'p');
    final data = jsonDecode(saved.last!);
    for (final c in data['cookies']) {
      c['expires'] = '2000-01-01T00:00:00Z';
    }
    final restored = HermesDashboardAuth(
        baseUrl: auth.baseUrl,
        savedSession: jsonEncode(data),
        onSessionChanged: (s) async {});
    try {
      await restored.currentIdentity();
      expect(cookieHeader, isEmpty);
    } finally {
      restored.close();
    }
  });
  test('rejects changed origin mount and foreign cookie domain on restore',
      () async {
    await auth.signIn('u', 'p');
    for (final url in [
      'http://127.0.0.1:${server.port}/other',
      'http://127.0.0.1:1/m'
    ]) {
      expect(
          () => HermesDashboardAuth(
              baseUrl: Uri.parse(url),
              savedSession: saved.last,
              onSessionChanged: (s) async {}),
          throwsA(isA<AuthException>()));
    }
    final data = jsonDecode(saved.last!);
    data['cookies'][0]['domain'] = 'evil.invalid';
    expect(
        () => HermesDashboardAuth(
            baseUrl: auth.baseUrl,
            savedSession: jsonEncode(data),
            onSessionChanged: (s) async {}),
        throwsA(isA<AuthException>()));
  });
  test('foreign domain and invalid Secure cookies fail closed', () async {
    for (final c in [
      'sid=x; Domain=evil.invalid; Path=/m',
      '__Host-sid=x; Secure; Path=/'
    ]) {
      cookies = [c];
      await expectLater(auth.signIn('u', 'p'), throwsA(isA<AuthException>()));
      expect(saved.last, isNull);
    }
  });
  test('logout accepts 302 but forgets locally even on connection failure',
      () async {
    await auth.signIn('u', 'p');
    await auth.signOut();
    expect(saved.last, isNull);
    await auth.signIn('u', 'p');
    await server.close(force: true);
    await expectLater(auth.signOut(), throwsA(isA<AuthException>()));
    expect(saved.last, isNull);
  });
  test(
      'URL credentials remote HTTP query fragment rejected; close has no callback',
      () async {
    for (final url in [
      'http://example.com',
      'https://u:p@example.com',
      'https://example.com/?secret=1',
      'https://example.com/#x'
    ]) {
      expect(
          () => HermesDashboardAuth(
              baseUrl: Uri.parse(url), onSessionChanged: (s) async {}),
          throwsA(isA<AuthException>()));
    }
    auth.close();
    await expectLater(auth.currentIdentity(), throwsA(isA<AuthException>()));
    expect(saved, isEmpty);
  });
}
