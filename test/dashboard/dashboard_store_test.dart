import 'dart:async';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'package:saathi/dashboard/dashboard_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
      'login, secure restore validation, fresh ticket, list and attach, forget',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecrets();
    final store =
        DashboardStore(SaathiStore(preferences: prefs, secrets: secrets));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    final methods = <String>[];
    var tickets = 0;
    var wrong = false;
    server.listen((r) async {
      paths.add(r.uri.path);
      if (r.uri.path == '/api/ws') {
        expect(r.headers.value('authorization'), isNull);
        expect(r.cookies, isEmpty);
        expect(r.headers.value('sec-websocket-protocol'),
            contains('hermes-gateway-ticket.t$tickets'));
        final ws = await WebSocketTransformer.upgrade(r,
            protocolSelector: (_) => 'hermes-gateway-v1');
        ws.listen((frame) {
          final q = jsonDecode(frame as String) as Map;
          methods.add(q['method'] as String);
          final result = switch (q['method']) {
            'runtime.describe' => {
                'profile_id': 'p',
                'capabilities': ['durable-admission-v1']
              },
            'session.list' => {
                'sessions': [
                  {'session_id': 's', 'title': 'Remote'}
                ]
              },
            _ => {
                'session_id': 's',
                'stored_session_id': 's',
                'authority_epoch': 1,
                'execution_generation': 1,
                'replay_epoch': 'r',
                'last_sequence': 0,
                'messages': [
                  {'role': 'assistant', 'content': 'Safe text'},
                  {'role': 'system', 'content': 'hidden'}
                ]
              }
          };
          ws.add(
              jsonEncode({'jsonrpc': '2.0', 'id': q['id'], 'result': result}));
        });
        return;
      }
      r.response.headers.contentType = ContentType.json;
      switch (r.uri.path) {
        case '/api/auth/providers':
          r.response.write(
              '{"providers":[{"name":"basic","supports_password":true}]}');
        case '/auth/password-login':
          final body = jsonDecode(await utf8.decoder.bind(r).join());
          wrong = body['password'] != ' private password ';
          if (wrong) {
            r.response.statusCode = 401;
            r.response.write('private password');
          } else {
            r.response.cookies
                .add(Cookie('session', 'cookie-secret')..path = '/');
            r.response.write('{"ok":true}');
          }
        case '/api/auth/me':
          expect(r.cookies.single.value, 'cookie-secret');
          r.response.write(
              '{"user_id":"u","provider":"basic","display_name":"User"}');
        case '/api/auth/ws-ticket':
          expect(paths[paths.length - 2], '/api/auth/me');
          tickets++;
          r.response.write('{"ticket":"t$tickets","ttl_seconds":30}');
        default:
          r.response.statusCode = 500;
      }
      await r.response.close();
    });
    addTearDown(() async {
      store.close();
      await server.close(force: true);
    });
    final url = 'http://127.0.0.1:${server.port}';
    await expectLater(
        store.signIn(
            name: 'Local', baseUrl: url, username: 'u', password: 'wrong'),
        throwsA(anything));
    expect(await store.load(), isEmpty);
    final failedStore = DashboardStore(
        SaathiStore(preferences: prefs, secrets: _FailSecrets()));
    await expectLater(
        failedStore.signIn(
            name: 'Local',
            baseUrl: url,
            username: 'u',
            password: ' private password '),
        throwsA(anything));
    expect(await failedStore.load(), isEmpty);
    failedStore.close();
    final entry = await store.signIn(
        name: 'Local',
        baseUrl: url,
        username: 'u',
        password: ' private password ');
    final raw = prefs.getString(DashboardStore.preferencesKey)!;
    expect(raw, isNot(contains('password')));
    expect(raw, isNot(contains('cookie-secret')));
    expect(raw, isNot(contains('username')));
    expect(await secrets.read(DashboardStore.secretId(entry.id)),
        contains('cookie-secret'));
    store.close();
    final restored =
        DashboardStore(SaathiStore(preferences: prefs, secrets: secrets));
    addTearDown(restored.close);
    expect((await restored.open(entry)).displayName, 'User');
    final gateway = await restored.connect(entry);
    expect((await gateway.listSessions()).single.id, 's');
    expect((await gateway.listSessions(stored: true)).single.id, 's');
    expect((await gateway.attach('s')).messages.single.text, 'Safe text');
    await gateway.dispose();
    final second = await restored.connect(entry);
    await second.dispose();
    expect(tickets, 2);
    expect(methods, isNot(contains('prompt.submit')));
    await restored.remove(entry);
    expect(await restored.load(), isEmpty);
    expect(await secrets.read(DashboardStore.secretId(entry.id)), isNull);
  });
  for (final cancel in [false, true]) {
    test(
        '${cancel ? 'cancel' : 'close'} during metadata write cancels login and removes credentials',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final started = Completer<void>(), release = Completer<void>();
      SharedPreferencesStorePlatform.instance =
          MethodChannelSharedPreferencesStore();
      const channel = MethodChannel('plugins.flutter.io/shared_preferences');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setString' && !started.isCompleted) {
          started.complete();
          await release.future;
        }
        return true;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final secrets = _TrackingSecrets();
      final store =
          DashboardStore(SaathiStore(preferences: prefs, secrets: secrets));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        r.response.headers.contentType = ContentType.json;
        if (r.uri.path.endsWith('providers')) {
          r.response.write(
              '{"providers":[{"name":"basic","supports_password":true}]}');
        } else if (r.uri.path.endsWith('password-login')) {
          await r.drain<void>();
          r.response.cookies.add(Cookie('s', 'v')..path = '/');
          r.response.write('{"ok":true}');
        } else {
          r.response.write(
              '{"user_id":"u","provider":"basic","display_name":"User"}');
        }
        await r.response.close();
      });
      addTearDown(() async {
        store.close();
        await server.close(force: true);
      });
      final cancellation = DashboardLoginCancellation();
      final pending = store.signIn(
          cancellation: cancellation,
          name: 'X',
          baseUrl: 'http://127.0.0.1:${server.port}',
          username: 'u',
          password: 'p');
      final checked = expectLater(pending, throwsA(anything));
      await started.future;
      if (cancel) {
        cancellation.cancel();
      } else {
        store.close();
      }
      expect(await store.load(), isEmpty);
      release.complete();
      await checked;
      expect(await store.load(), isEmpty);
      expect(secrets.values, isEmpty);
    });
  }
  test('failed secure storage never reports successful login', () async {
    SharedPreferences.setMockInitialValues({});
    final store = DashboardStore(SaathiStore(
        preferences: await SharedPreferences.getInstance(),
        secrets: _FailSecrets()));
    await expectLater(
        store.open(const DashboardConnection(
            id: 'x', name: 'X', baseUrl: 'https://example.com/')),
        throwsA(anything));
    store.close();
  });
}

class _TrackingSecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class _FailSecrets implements SecretStore {
  @override
  Future<String?> read(String id) async => throw StateError('private');
  @override
  Future<void> write(String id, String value) async =>
      throw StateError('private');
  @override
  Future<void> delete(String id) async => throw StateError('private');
}
