import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/updates/saathi_updates.dart';
import 'saathi_updates_test.dart' show ReleaseFixture;

void main() {
  test('only marked human bullets are notes; malformed notes are optional',
      () async {
    final fixture = ReleaseFixture();
    fixture.release['body'] =
        'Technical boilerplate\n<!-- saathi-changes:start -->\n- A useful change.\n- [Read](https://evil.test) <img src="x">\n<!-- saathi-changes:end -->\nSHA: abc';
    final service = fixture.service(installed: UpdateVersion.parse('1.1.0', 2));
    expect(await service.check(), isNull);
    expect(service.releaseNotes.single.changes,
        ['A useful change.', '[Read](https://evil.test) <img src="x">']);
    expect(fixture.requests, 2);
    fixture.release['body'] = 42;
    expect(await service.check(), isNull);
    expect(service.releaseNotes.single.changes, isEmpty);
  });
  test(
      'bundled history excludes unreleased, merges by version and sorts numerically',
      () {
    final bundled = ReleaseNotes.fromChangelog(jsonEncode({
      'schema': 1,
      'unreleased': ['Not released'],
      'releases': [
        {
          'version': '1.9.0',
          'changes': ['Older']
        },
        {
          'version': '1.10.0',
          'changes': ['Known']
        }
      ]
    }));
    final history = ReleaseNotes.merge(bundled, [
      ReleaseNotes('1.10.0', []),
      ReleaseNotes('1.11.0', ['Future'])
    ]);
    expect(history.map((e) => e.version), ['1.11.0', '1.10.0', '1.9.0']);
    expect(history[1].changes, ['Known']);
    expect(history.expand((e) => e.changes), isNot(contains('Not released')));
  });
}
