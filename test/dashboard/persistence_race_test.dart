import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/auth/hermes_dashboard_auth.dart';

void main() {
  test('refresh persistence is serialized beyond HTTP deadline before logout',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var refresh = false;
    final started = Completer<void>(), release = Completer<void>();
    String? saved;
    var logout = false;
    server.listen((r) async {
      r.response.headers.contentType = ContentType.json;
      switch (r.uri.path) {
        case '/api/auth/providers':
          r.response.write(
              '{"providers":[{"name":"basic","supports_password":true}]}');
        case '/auth/password-login':
          await r.drain<void>();
          r.response.cookies.add(Cookie('s', 'old')..path = '/');
          r.response.write('{"ok":true}');
        case '/api/auth/me':
          if (refresh) {
            r.response.cookies.add(Cookie('s', 'rotated')..path = '/');
          }
          r.response.write(jsonEncode(
              {'user_id': 'u', 'provider': 'basic', 'display_name': 'User'}));
        default:
          logout = true;
          r.response.write('{}');
      }
      await r.response.close();
    });
    final auth = HermesDashboardAuth(
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}/'),
        onSessionChanged: (v) async {
          if (refresh && v != null) {
            if (!started.isCompleted) started.complete();
            await release.future;
          }
          saved = v;
        });
    addTearDown(() async {
      auth.close();
      await server.close(force: true);
    });
    await auth.signIn('u', 'p');
    refresh = true;
    var finished = false;
    Object? failure;
    final pending = auth.currentIdentity().then<void>((_) {
      finished = true;
    }, onError: (Object e) {
      failure = e;
      finished = true;
    });
    await started.future;
    final signout = auth.signOut();
    await Future<void>.delayed(const Duration(seconds: 16));
    expect(finished, isFalse,
        reason: 'Secure writes must not be detached by HTTP timeout');
    expect(logout, isFalse);
    release.complete();
    await pending;
    await signout;
    expect(failure, isNull);
    expect(saved, isNull);
  }, timeout: const Timeout(Duration(seconds: 25)));
}
