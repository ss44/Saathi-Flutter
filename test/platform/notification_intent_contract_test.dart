import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native tap intent survives engine recreation until Dart consumes it',
      () {
    final source = File(
            'android/app/src/main/kotlin/io/github/ss44/saathi/ReplyNotifications.kt')
        .readAsStringSync();
    expect(source,
        contains('"consumePendingTap" -> result.success(consumePendingTap())'));
    final accept =
        RegExp(r'fun accept\(intent: Intent\?\) \{([\s\S]*?)\n    \}')
            .firstMatch(source);
    expect(accept, isNotNull);
    expect(accept!.group(1), isNot(contains('Intent.ACTION_MAIN')));
    expect(source, contains('private fun consumePendingTap()'));
    expect(source, contains('taps.size >= 32'));
  });
}
