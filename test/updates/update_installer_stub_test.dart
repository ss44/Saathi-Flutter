import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/updates/saathi_updates.dart';
import 'package:saathi/updates/update_installer_stub.dart' as stub;

import 'saathi_updates_test.dart' show ReleaseFixture;

void main() {
  test('unsupported installer rejects a real verified update', () async {
    final service = ReleaseFixture().service();
    addTearDown(service.close);
    final offer = await service.check();
    final verified = await service.download(offer!);
    await expectLater(
      stub.installVerifiedAndroidUpdate(verified),
      throwsA(isA<UpdateException>().having((error) => error.message, 'message',
          'Android installation is unavailable here')),
    );
  });
}
