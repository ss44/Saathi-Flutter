import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/auth/hermes_dashboard_auth.dart';

void main() {
  test(
      'login validates identity before persisting cookie session, never password',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    server.listen((r) async {
      paths.add(r.uri.path);
      r.response.headers.contentType = ContentType.json;
      switch (r.uri.path) {
        case '/mount/api/auth/providers':
          r.response.write(jsonEncode({
            'providers': [
              {'name': 'basic', 'supports_password': true}
            ]
          }));
        case '/mount/auth/password-login':
          final body = jsonDecode(await utf8.decoder.bind(r).join());
          expect(body['username'], ' user ');
          expect(body['password'], ' password ');
          expect(r.headers.value('authorization'), isNull);
          r.response.cookies.add(Cookie('dynamic_gateway', 'session-secret')
            ..path = '/mount'
            ..maxAge = 60);
          r.response.write('{"ok":true,"next":"/mount/"}');
        case '/mount/api/auth/me':
          expect(r.cookies.single.value, 'session-secret');
          r.response.write(
              '{"user_id":"u","provider":"basic","display_name":"User","expires_at":1900000000}');
        default:
          r.response.statusCode = 404;
      }
      await r.response.close();
    });
    String? saved;
    final auth = HermesDashboardAuth(
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}/mount'),
        onSessionChanged: (s) async {
          expect(paths.last, '/mount/api/auth/me');
          saved = s;
        });
    try {
      expect((await auth.signIn(' user ', ' password ')).userId, 'u');
      expect(saved, contains('session-secret'));
      expect(saved, isNot(contains('password')));
    } finally {
      auth.close();
      await server.close(force: true);
    }
  });
}
