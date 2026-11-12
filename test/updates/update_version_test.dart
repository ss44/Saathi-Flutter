import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/updates/update_version.dart';

void main() {
  test('hex-like and signed prerelease identifiers are lexical, not numeric',
      () {
    final candidate = UpdateVersion.parse('1.0.0-beta.0x1', 3);
    final installed = UpdateVersion.parse('1.0.0-beta.2', 2);
    expect(candidate.isNewerThan(installed), isTrue);
  });

  test('signed prerelease identifiers sort after numeric identifiers', () {
    expect(
        UpdateVersion.parse('1.0.0--1', 3)
            .compareTo(UpdateVersion.parse('1.0.0-1', 2)),
        greaterThan(0));
  });

  test('decimal prerelease identifiers retain numeric SemVer ordering', () {
    expect(
        UpdateVersion.parse('1.0.0-beta.10', 3)
            .compareTo(UpdateVersion.parse('1.0.0-beta.2', 2)),
        greaterThan(0));
    expect(
        UpdateVersion.parse('1.0.0-beta.0', 3)
            .compareTo(UpdateVersion.parse('1.0.0-beta.1', 2)),
        lessThan(0));
    expect(
        UpdateVersion.parse('1.0.0-beta.999999999999999999999', 3)
            .compareTo(UpdateVersion.parse('1.0.0-beta.10', 2)),
        greaterThan(0));
  });
}
