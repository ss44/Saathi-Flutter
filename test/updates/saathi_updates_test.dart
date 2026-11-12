import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/updates/saathi_updates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native bridge gets a private-cache hash-verified APK path', () async {
    final cache = await Directory.systemTemp.createTemp('saathi-update-test-');
    final fixture = ReleaseFixture();
    final methods = <String>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('saathi/updates');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'getCacheDirectory') return cache.path;
      if (call.method == 'installApk') {
        final path = (call.arguments as Map)['path'] as String;
        expect(File(path).parent.path, cache.path);
        expect(await File(path).readAsBytes(), fixture.apk);
        return null;
      }
      throw MissingPluginException();
    });
    final updates = SaathiUpdateController(service: fixture.service());
    try {
      await updates.check(force: true);
      await updates.installAndroid(userConsented: true);
      expect(methods, ['getCacheDirectory', 'installApk']);
      expect(updates.status, UpdateStatus.handedOff);
    } finally {
      updates.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await cache.delete(recursive: true);
    }
  });
  test('controller needs explicit consent before download or browser launch',
      () async {
    final fixture = ReleaseFixture();
    var installs = 0;
    var launches = 0;
    final updates = SaathiUpdateController(
        service: fixture.service(),
        installer: (_) async {
          installs++;
          return true;
        },
        openUrl: (_) async {
          launches++;
          return true;
        });
    await updates.check(force: true);
    expect(updates.status, UpdateStatus.available);
    await updates.installAndroid(userConsented: false);
    await updates.openReleasePage(userConsented: false);
    expect(installs, 0);
    expect(launches, 0);
    expect(fixture.requests, 2);
    await updates.installAndroid(userConsented: true);
    expect(installs, 1);
    expect(updates.status, UpdateStatus.handedOff);
    updates.dispose();
  });
  test('controller startup and resume checks are throttled', () async {
    final fixture = ReleaseFixture();
    final updates = SaathiUpdateController(service: fixture.service());
    updates.start();
    await updates.check();
    final requests = fixture.requests;
    updates.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await updates.check();
    expect(fixture.requests, requests);
    await updates.check(force: true);
    expect(fixture.requests, greaterThan(requests));
    updates.dispose();
  });
  test('unconfigured updater fails closed without requests', () async {
    var requests = 0;
    final service = SaathiUpdateService(
      config: const UpdateConfig(),
      installed: UpdateVersion.parse('1.0.0', 1),
      client: MockClient((_) async {
        requests++;
        return http.Response('', 500);
      }),
    );
    expect(await service.check(), isNull);
    expect(requests, 0);
  });
  test('checks release metadata, downloads and verifies exact artifact',
      () async {
    final fixture = ReleaseFixture();
    final service = fixture.service();
    final offer = await service.check();
    expect(offer?.version.toString(), '1.1.0+2');
    final verified = await service.download(offer!);
    expect(verified.bytes, fixture.apk);
    expect(verified.offer, same(offer));
  });
  test('rejects checksum mismatches before installer invocation', () async {
    final fixture = ReleaseFixture();
    fixture.downloadBytes = List.filled(fixture.apk.length, 0);
    var installs = 0;
    final updates = SaathiUpdateController(
        service: fixture.service(),
        installer: (_) async {
          installs++;
          return true;
        });
    await updates.check(force: true);
    await updates.installAndroid(userConsented: true);
    expect(installs, 0);
    expect(updates.status, UpdateStatus.error);
    updates.dispose();
  });
  test('rejects truncated or oversized artifacts', () async {
    for (final extra in [-1, 1]) {
      final fixture = ReleaseFixture();
      final service = fixture.service();
      final offer = await service.check();
      fixture.downloadBytes = List.filled(fixture.apk.length + extra, 0);
      await expectLater(
          service.download(offer!), throwsA(isA<UpdateException>()));
    }
  });
  test('rejects unsafe and cross-repository artifact URLs', () async {
    for (final url in [
      'http://github.com/example/saathi/releases/download/v1.1.0+2/saathi.apk',
      'https://github.com/attacker/saathi/releases/download/v1.1.0+2/saathi.apk',
      'https://github.com.evil.test/example/saathi/releases/download/v1.1.0+2/saathi.apk',
      'https://user@github.com/example/saathi/releases/download/v1.1.0+2/saathi.apk',
    ]) {
      final fixture = ReleaseFixture();
      fixture.manifest['asset']['url'] = url;
      await expectLater(
          fixture.service().check(), throwsA(isA<UpdateException>()));
    }
  });
  test('Play builds and invalid config never request external releases',
      () async {
    for (final config in [
      const UpdateConfig(
          owner: 'example', repo: 'saathi', distribution: 'play'),
      const UpdateConfig(owner: 'example', repo: '../saathi'),
      const UpdateConfig(owner: 'example', repo: 'saathi', channel: 'nightly'),
    ]) {
      final fixture = ReleaseFixture();
      expect(await fixture.service(config: config).check(), isNull);
      expect(fixture.requests, 0);
    }
  });
  test('rejects stable-channel prerelease manifest', () async {
    final fixture = ReleaseFixture();
    fixture.manifest['version'] = '1.1.0-beta.1';
    await expectLater(
        fixture.service().check(), throwsA(isA<UpdateException>()));
  });
  test('same build and older versions do not produce offers', () async {
    for (final installed in [
      UpdateVersion.parse('1.1.0', 2),
      UpdateVersion.parse('1.2.0', 3),
      UpdateVersion.parse('1.0.0', 3)
    ]) {
      final fixture = ReleaseFixture();
      expect(await fixture.service(installed: installed).check(), isNull);
    }
  });
  test('rejects mismatched GitHub digest', () async {
    final fixture = ReleaseFixture();
    fixture.release['assets'][1]['digest'] = 'sha256:${'0' * 64}';
    await expectLater(
        fixture.service().check(), throwsA(isA<UpdateException>()));
  });
  test('manifest schema is strictly an integer', () async {
    final fixture = ReleaseFixture();
    fixture.manifest['schema'] = 1.0;
    await expectLater(
        fixture.service().check(), throwsA(isA<UpdateException>()));
  });
  test('unsafe redirect never reaches installer', () async {
    for (final location in [
      'http://release-assets.githubusercontent.com/a',
      'https://evil.test/a',
      'https://github.com/other/repo/releases/download/x/app.apk'
    ]) {
      final fixture = ReleaseFixture();
      fixture.responseOverride = (request) => request.url.path.endsWith('.apk')
          ? http.Response('', 302, headers: {'location': location})
          : null;
      final service = fixture.service();
      final offer = await service.check();
      await expectLater(
          service.download(offer!), throwsA(isA<UpdateException>()));
    }
  });
  test('follows only GitHub HTTPS release CDN redirect and verifies hash',
      () async {
    final fixture = ReleaseFixture();
    fixture.responseOverride = (request) {
      if (request.url.host == 'release-assets.githubusercontent.com') {
        return http.Response.bytes(fixture.apk, 200);
      }
      if (request.url.path.endsWith('.apk')) {
        return http.Response('', 302, headers: {
          'location':
              'https://release-assets.githubusercontent.com/github-production-release-asset/a?token=example'
        });
      }
      return null;
    };
    final service = fixture.service();
    final offer = await service.check();
    expect((await service.download(offer!)).bytes, fixture.apk);
  });
  test('unknown content length is still bounded while streaming', () async {
    final fixture = ReleaseFixture();
    final client = MockClient.streaming((request, body) async {
      if (request.url.host == 'api.github.com') {
        return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode([fixture.release]))), 200);
      }
      if (request.url.path.endsWith('.json')) {
        return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(fixture.manifest))), 200);
      }
      return http.StreamedResponse(
          Stream.fromIterable([
            List.filled(fixture.apk.length, 0),
            [1]
          ]),
          200);
    });
    final service = fixture.service(client: client);
    final offer = await service.check();
    await expectLater(
        service.download(offer!), throwsA(isA<UpdateException>()));
  });
  test('offers cannot cross updater instances', () async {
    final fixture = ReleaseFixture();
    final offer = await fixture.service().check();
    await expectLater(
        fixture.service().download(offer!), throwsA(isA<UpdateException>()));
  });
  test('beta channel accepts only its explicitly published manifest', () async {
    final fixture = ReleaseFixture();
    fixture.manifest['version'] = '1.1.0-beta.1';
    fixture.manifest['channel'] = 'beta';
    fixture.manifest['asset']['url'] =
        'https://github.com/example/saathi/releases/download/v1.1.0-beta.1+2/saathi.apk';
    fixture.release['tag_name'] = 'v1.1.0-beta.1+2';
    fixture.release['prerelease'] = true;
    fixture.release['html_url'] =
        'https://github.com/example/saathi/releases/tag/v1.1.0-beta.1+2';
    fixture.release['assets'][0]['name'] = 'saathi-update-beta.json';
    fixture.release['assets'][0]['browser_download_url'] =
        'https://github.com/example/saathi/releases/download/v1.1.0-beta.1+2/saathi-update-beta.json';
    final offer = await fixture
        .service(
            config: const UpdateConfig(
                owner: 'example', repo: 'saathi', channel: 'beta'))
        .check();
    expect(offer?.version.name, '1.1.0-beta.1');
  });
  test('permission settings handoff is actionable, not installed', () async {
    final fixture = ReleaseFixture();
    final updates = SaathiUpdateController(
        service: fixture.service(),
        installer: (_) async =>
            throw PlatformException(code: 'install_permission_required'));
    await updates.check(force: true);
    await updates.installAndroid(userConsented: true);
    expect(updates.status, UpdateStatus.error);
    expect(updates.error, contains('tap Install again'));
    updates.dispose();
  });
  test('version comparison respects semver precedence and build number', () {
    expect(
        UpdateVersion.parse('1.2.0', 10)
            .isNewerThan(UpdateVersion.parse('1.1.9', 9)),
        isTrue);
    expect(
        UpdateVersion.parse('1.2.0', 3)
            .isNewerThan(UpdateVersion.parse('1.2.0', 2)),
        isTrue);
    expect(
        UpdateVersion.parse('1.2.0-beta.2', 4)
            .isNewerThan(UpdateVersion.parse('1.2.0-beta.1', 3)),
        isTrue);
    expect(
        UpdateVersion.parse('1.2.0-beta.1', 5)
            .isNewerThan(UpdateVersion.parse('1.2.0', 4)),
        isFalse);
    expect(() => UpdateVersion.parse('1.02.0', 2), throwsFormatException);
    expect(() => UpdateVersion.parse('1.0.0', -1), throwsFormatException);
  });
}

class ReleaseFixture {
  final apk = utf8.encode('test APK bytes, never a production APK');
  late final manifest = <String, dynamic>{
    'schema': 1,
    'version': '1.1.0',
    'build': 2,
    'channel': 'stable',
    'platform': 'android',
    'asset': {
      'name': 'saathi.apk',
      'size': apk.length,
      'sha256': sha256.convert(apk).toString(),
      'url':
          'https://github.com/example/saathi/releases/download/v1.1.0+2/saathi.apk'
    },
  };
  late final release = <String, dynamic>{
    'tag_name': 'v1.1.0+2',
    'draft': false,
    'prerelease': false,
    'html_url': 'https://github.com/example/saathi/releases/tag/v1.1.0+2',
    'assets': [
      {
        'name': 'saathi-update-stable.json',
        'state': 'uploaded',
        'size': utf8.encode(jsonEncode(manifest)).length,
        'browser_download_url':
            'https://github.com/example/saathi/releases/download/v1.1.0+2/saathi-update-stable.json'
      },
      {
        'name': 'saathi.apk',
        'state': 'uploaded',
        'size': apk.length,
        'browser_download_url': manifest['asset']['url']
      },
    ],
  };
  http.Response? Function(http.Request)? responseOverride;
  List<int>? downloadBytes;
  int requests = 0;
  SaathiUpdateService service(
          {UpdateConfig? config,
          UpdateVersion? installed,
          http.Client? client}) =>
      SaathiUpdateService(
        config: config ?? const UpdateConfig(owner: 'example', repo: 'saathi'),
        installed: installed ?? UpdateVersion.parse('1.0.0', 1),
        client: client ??
            MockClient((request) async {
              requests++;
              final override = responseOverride?.call(request);
              if (override != null) return override;
              if (request.url.host == 'api.github.com') {
                return http.Response(jsonEncode([release]), 200);
              }
              if (request.url.path.endsWith('.json')) {
                return http.Response(jsonEncode(manifest), 200);
              }
              return http.Response.bytes(downloadBytes ?? apk, 200);
            }),
      );
}
