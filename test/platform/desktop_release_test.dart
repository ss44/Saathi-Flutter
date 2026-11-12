import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/storage/saathi_store.dart';

void main() {
  test('Windows runner presents Saathi and uses build-time version resources',
      () {
    final runner = File('windows/runner/main.cpp').readAsStringSync();
    final resource = File('windows/runner/Runner.rc').readAsStringSync();
    expect(runner, contains('window.Create(L"Saathi"'));
    expect(resource, contains('"ProductName", "Saathi"'));
    expect(resource, contains('FLUTTER_VERSION_BUILD'));
    expect(File('windows/runner/resources/app_icon.ico').existsSync(), isTrue);
  });
  test('standalone macOS storage does not require a team provisioning profile',
      () {
    expect(
        const PlatformSecrets()
            .storage
            .mOptions
            .toMap()['usesDataProtectionKeychain'],
        'false');
    for (final name in ['DebugProfile', 'Release']) {
      final entitlements =
          File('macos/Runner/$name.entitlements').readAsStringSync();
      expect(entitlements, isNot(contains('keychain-access-groups')));
    }
  });
}
