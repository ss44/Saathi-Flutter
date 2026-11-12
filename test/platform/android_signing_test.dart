import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release signing explicitly supports the generated PKCS12 keystore', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle,
        contains('storeType = releaseKeys.getProperty("storeType", "PKCS12")'));
    expect(gradle,
        isNot(contains('signingConfig = signingConfigs.getByName("debug")')));
  });
}
