import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'Android installer is private-cache-only and checks app identity/signing',
      () {
    final activity = File(
        'android/app/src/main/kotlin/io/github/ss44/saathi/MainActivity.kt');
    expect(activity.existsSync(), isTrue,
        reason: 'Saathi needs a native updater bridge');
    final source = activity.readAsStringSync();
    expect(source, contains('saathi/updates'));
    expect(source, contains('installApk'));
    expect(source, contains('canonicalFile'));
    expect(source, contains('getPackageArchiveInfo'));
    expect(source, contains('signaturesMatch'));
    expect(source, contains('canRequestPackageInstalls'));
    expect(source, contains('FileProvider.getUriForFile'));
    expect(source, contains('ACTION_VIEW'));
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android.permission.REQUEST_INSTALL_PACKAGES'));
    expect(manifest, contains('android:exported="false"'));
    expect(manifest, contains('androidx.core.content.FileProvider'));
  });
}
