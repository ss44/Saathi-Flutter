import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/auth/hermes_dashboard_auth.dart';

void main() {
  for (final mode in ['count', 'size', 'login']) {
    final size = mode == 'size';
    test('aggregate cookie $mode overflow is transactional', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var overflow = mode == 'login';
      final states = <String?>[];
      server.listen((r) async {
        r.response.headers.contentType = ContentType.json;
        if (r.uri.path.endsWith('providers')) {
          r.response.write(
              '{"providers":[{"name":"basic","supports_password":true}]}');
        } else if (r.uri.path.endsWith('password-login')) {
          await r.drain<void>();
          for (var i = 0; i < (size ? 1 : 64); i++) {
            r.response.cookies
                .add(Cookie('c$i', size ? 'x' * 32000 : 'v')..path = '/');
          }
          r.response.write('{"ok":true}');
        } else {
          if (overflow) {
            r.response.cookies
                .add(Cookie('new', size ? 'y' * 34000 : 'v')..path = '/');
          }
          r.response.write(
              '{"user_id":"u","provider":"basic","display_name":"User"}');
        }
        await r.response.close();
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      final auth = HermesDashboardAuth(
          baseUrl: base,
          onSessionChanged: (v) async {
            states.add(v);
          });
      addTearDown(() async {
        auth.close();
        await server.close(force: true);
      });
      if (mode == 'login') {
        await expectLater(auth.signIn('u', 'p'), throwsA(isA<AuthException>()));
        expect(states.whereType<String>(), isEmpty);
        return;
      }
      await auth.signIn('u', 'p');
      final saved = states.single!;
      overflow = true;
      await expectLater(auth.currentIdentity(), throwsA(isA<AuthException>()));
      expect(states, [saved]);
      overflow = false;
      await auth.currentIdentity();
      final restored = HermesDashboardAuth(
          baseUrl: base, savedSession: saved, onSessionChanged: (_) async {});
      await restored.currentIdentity();
      restored.close();
      expect((jsonDecode(saved)['cookies'] as List).length, size ? 1 : 64);
    });
  }
}
