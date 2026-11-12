import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('platform runners use Saathi identity rather than Iris examples', () {
    final android =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final linux = File('linux/CMakeLists.txt').readAsStringSync();
    final mac =
        File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync();
    expect(android, contains('android:label="Saathi"'));
    expect(android, contains('android.permission.INTERNET'));
    expect(gradle, contains('io.github.ss44.saathi'));
    expect(gradle, isNot(contains('com.example.iris')));
    expect(linux, contains('set(BINARY_NAME "saathi")'));
    expect(mac, contains('PRODUCT_NAME = Saathi'));
    expect(mac, contains('PRODUCT_BUNDLE_IDENTIFIER = io.github.ss44.saathi'));
    for (final name in ['DebugProfile', 'Release']) {
      final entitlements =
          File('macos/Runner/$name.entitlements').readAsStringSync();
      expect(entitlements, contains('com.apple.security.network.client'));
      expect(entitlements, isNot(contains('keychain-access-groups')));
    }
    expect(android, contains('android:allowBackup="false"'));
    expect(gradle,
        isNot(contains('signingConfig = signingConfigs.getByName("debug")')));
  });
}
