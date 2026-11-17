import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/storage/saathi_store.dart';
import 'runtime_flow_test.dart' show RuntimeFixture;
import 'runtime_recovery_test.dart' show connect, DelayedSecrets;

class RotationSecrets extends MemorySecrets {
  bool hold = false;
  final entered = Completer<void>(), release = Completer<void>();
  bool failWrite = false;
  @override
  Future<String?> read(String id) async {
    if (hold && id == 'h' && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.read(id);
  }

  bool holdWrite = false;
  final writeEntered = Completer<void>(), writeRelease = Completer<void>();
  @override
  Future<void> write(String id, String value) async {
    if (holdWrite && id == 'h') {
      if (!writeEntered.isCompleted) writeEntered.complete();
      await writeRelease.future;
    }
    if (failWrite && id == 'h') {
      failWrite = false;
      throw StateError('Controlled replacement failure');
    }
    await super.write(id, value);
  }
}

void main() {
  for (final stop in [false, true]) {
    test(
        'failed mutation permanently revokes delayed ${stop ? 'stop' : 'guide'}',
        () async {
      final f = RuntimeFixture();
      await f.start();
      final secrets = RotationSecrets();
      final c = await connect(f, secrets: secrets);
      try {
        await c.send('original');
        final original = c.connections.single;
        secrets.hold = true;
        final pending = c.controlRun(guidance: stop ? null : 'revoked guide');
        await secrets.entered.future;
        secrets.failWrite = true;
        await expectLater(
            c.updateConnection('h', {...original}, apiKey: 'failed-fixture'),
            throwsStateError);
        expect(c.changingConnection, isFalse);
        expect(c.connections.single, same(original));
        secrets.release.complete();
        expect(await pending, isFalse);
        expect(f.guides, isEmpty);
        expect(
            f.requests
                .where((r) => r.contains('/steer') || r.contains('/stop')),
            isEmpty);
      } finally {
        c.dispose();
        await f.close();
      }
    });
  }
  test('credential rotation in progress revokes delayed guide', () async {
    final f = RuntimeFixture();
    await f.start();
    final secrets = RotationSecrets();
    final c = await connect(f, secrets: secrets);
    Future<void>? mutation;
    try {
      await c.send('original');
      secrets.hold = true;
      final pending = c.controlRun(guidance: 'guide using old key');
      await secrets.entered.future;
      secrets.holdWrite = true;
      mutation = c.updateConnection('h', {...c.connections.single},
          apiKey: 'rotated-fixture');
      secrets.release.complete();
      await secrets.writeEntered.future;
      expect(c.changingConnection, isTrue);
      await pending;
      expect(f.guides, isEmpty,
          reason: 'No native write during credential replacement');
    } finally {
      if (!secrets.writeRelease.isCompleted) secrets.writeRelease.complete();
      await mutation;
      c.dispose();
      await f.close();
    }
  });
  for (final stop in [false, true]) {
    test(
        'control session round trip must revoke delayed ${stop ? 'stop' : 'guide'} dispatch',
        () async {
      final f = RuntimeFixture();
      await f.start();
      final secrets = DelayedSecrets();
      final c = await connect(f, secrets: secrets);
      try {
        await c.send('original');
        final original = c.current!;
        await c.newSession(c.connections.single, 'other', '');
        final other = c.current!;
        c.select(original);
        secrets.hold = true;
        final pending =
            c.controlRun(guidance: stop ? null : 'old captured guidance');
        await secrets.entered.future;
        c.select(other);
        c.select(original);
        secrets.release.complete();
        expect(await pending, isFalse);
        expect(f.guides, isEmpty,
            reason:
                'A session round trip must not resurrect old control authority');
        expect(f.stopping, isFalse);
      } finally {
        c.dispose();
        await f.close();
      }
    });
  }
  for (final boundary in ['selection', 'failed mutation']) {
    test('native control panel cannot revive after $boundary', () async {
      final f = RuntimeFixture();
      await f.start();
      final secrets = RotationSecrets();
      final c = await connect(f, secrets: secrets);
      try {
        await c.send('original');
        final original = c.current!;
        final panel = await c.openRunControls(isOwnerCurrent: () => true);
        expect(panel, isNotNull);
        expect(panel!.isCurrent, isTrue);
        if (boundary == 'selection') {
          await c.newSession(c.connections.single, 'other', '');
          c.select(original);
        } else {
          secrets.failWrite = true;
          await expectLater(
              c.updateConnection('h', {...c.connections.single},
                  apiKey: 'failed-fixture'),
              throwsStateError);
        }
        expect(panel.isCurrent, isFalse);
        panel.dispose();
      } finally {
        c.dispose();
        await f.close();
      }
    });
  }
}
