import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/auth/hermes_dashboard_auth.dart';
import 'package:saathi/dashboard/dashboard_store.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  for (final remove in [false, true]) {
    for (final connect in [false, true]) {
      test(
          '${remove ? 'remove' : 'close'} during secure read blocks '
          '${connect ? 'connect' : 'open'} before HTTP publication', () async {
        SharedPreferences.setMockInitialValues({});
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        server.listen((request) async {
          requests++;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
              '{"user_id":"u","provider":"basic","display_name":"User"}');
          await request.response.close();
        });
        final entry = DashboardConnection(
            id: 'saved',
            name: 'Saved',
            baseUrl: 'http://127.0.0.1:${server.port}/');
        final secrets = _DelayedRead(jsonEncode({
          'version': 1,
          'base': entry.baseUrl,
          'cookies': <Object>[],
        }));
        final store = DashboardStore(SaathiStore(
            preferences: await SharedPreferences.getInstance(),
            secrets: secrets));
        addTearDown(() async {
          store.close();
          await server.close(force: true);
        });
        Object? failure;
        final pending = (connect ? store.connect(entry) : store.open(entry))
            .then<void>((_) {}, onError: (Object error) {
          failure = error;
        });
        await secrets.started.future;
        if (remove) {
          await store.remove(entry);
        } else {
          store.close();
        }
        secrets.release.complete();
        await pending;
        expect(requests, 0, reason: 'No broker may be created after disposal');
        expect(failure, isA<AuthException>());
      });
    }
  }
}

class _DelayedRead implements SecretStore {
  _DelayedRead(this.saved);
  final String saved;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> read(String id) async {
    started.complete();
    await release.future;
    return saved;
  }

  @override
  Future<void> write(String id, String value) async {}
  @override
  Future<void> delete(String id) async {}
}
