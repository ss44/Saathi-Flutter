import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android allows loopback development without global cleartext traffic',
      () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
        manifest,
        contains(
            'android:networkSecurityConfig="@xml/network_security_config"'));
    final file =
        File('android/app/src/main/res/xml/network_security_config.xml');
    expect(file.existsSync(), isTrue);
    final config = file.readAsStringSync();
    expect(config, contains('<base-config cleartextTrafficPermitted="false"'));
    expect(config, contains('127.0.0.1'));
    expect(config, contains('localhost'));
    expect(manifest, isNot(contains('android:usesCleartextTraffic="true"')));
  });
}
