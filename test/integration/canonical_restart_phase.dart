// Opt-in child process for tool/hermes_canonical_restart_probe.py.
// The filesystem secret store is test-only; production uses OS secure storage.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saathi/gateway/canonical_chat.dart';
import 'package:saathi/gateway/hermes_gateway.dart';
import 'package:saathi/gateway/host_invite.dart';
import 'package:saathi/storage/saathi_store.dart';

class ProbeSecrets implements SecretStore {
  ProbeSecrets(this.root);
  final Directory root;
  File file(String id) =>
      File('${root.path}/${sha256.convert(utf8.encode(id))}');
  @override
  Future<String?> read(String id) async =>
      await file(id).exists() ? file(id).readAsString() : null;
  @override
  Future<void> write(String id, String value) async {
    await root.create(recursive: true);
    final f = file(id);
    await f.writeAsString(value, flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', f.path]);
  }

  @override
  Future<void> delete(String id) async {
    if (await file(id).exists()) await file(id).delete();
  }
}

void main() {
  final rootPath = Platform.environment['CANONICAL_RESTART_ROOT'];
  test('official persisted canonical owner restart phase', () async {
    final root = Directory(rootPath!);
    final ready =
        jsonDecode(await File('${root.path}/ready.json').readAsString()) as Map;
    SecurityContext.defaultContext
        .setTrustedCertificates('${root.path}/cert.pem');
    final secrets = ProbeSecrets(Directory('${root.path}/dart-secrets'));
    final url = HostInviteVault.trustedSource(ready['proxyUrl'] as String);
    final invite = await File(ready['invitePath'] as String).readAsString();
    final exported = jsonDecode(invite) as Map<String, dynamic>;
    exported['url'] =
        url.toString(); // Explicit controlled TLS-forwarding export.
    final vault = HostInviteVault(secrets);
    await vault.import('restart-source', jsonEncode(exported), trustedUrl: url);
    final client = HermesGatewayClient(
        requestTimeout: const Duration(seconds: 15),
        grantProvider: () => vault.consume('restart-source', trustedUrl: url));
    final owner = CanonicalChat(client, secrets,
        source: 'restart-source', isCurrent: () => true);
    addTearDown(owner.close);
    await owner.connect();
    await owner.attach(ready['sessionId'] as String);
    final journalKey = 'gateway.journal.restart-source.${ready['sessionId']}';
    final phase = Platform.environment['CANONICAL_RESTART_PHASE'];
    if (phase == 'send') {
      await expectLater(owner.send('Lost ACK from actual Dart owner'),
          throwsA(isA<GatewayException>()));
      expect(owner.pending, isTrue);
      final journal = jsonDecode((await secrets.read(journalKey))!) as Map;
      expect(journal['state'], 'uncertain');
      expect(journal.containsKey('admissionId'), isFalse);
      expect(journal['inputId'], isNotEmpty);
      stdout.writeln('actual_dart_lost_ack_durable_journal=true');
    } else {
      expect(owner.pending, isTrue);
      final before = jsonDecode((await secrets.read(journalKey))!) as Map;
      final settled = await owner.refresh();
      final exact = owner.snapshot!.messages
          .where((m) => m.submissionId == before['inputId']);
      expect(exact, hasLength(1),
          reason: 'Official persisted metadata, not text matching');
      if (phase == 'receipt') {
        expect(settled, isFalse);
        final journal = jsonDecode((await secrets.read(journalKey))!) as Map;
        expect(journal['admissionId'], isNotEmpty);
        expect(client.run!.inputId, before['inputId']);
        expect(owner.pending, isTrue);
        stdout.writeln(
            'actual_dart_owner_process_restart_exact_pending_receipt=true');
      } else if (phase == 'terminal') {
        expect(settled, isTrue);
        expect(owner.pending, isTrue,
            reason: 'Durable history barrier still owns completion');
        await File('${root.path}/reconciled-history.json').writeAsString(
            jsonEncode([
              for (final row in owner.messages)
                {
                  'role': row.role,
                  'text': row.text,
                  'submission': row.submissionId
                }
            ]),
            flush: true);
        await owner.markSnapshotSaved();
        expect(owner.pending, isFalse);
        expect(await secrets.read(journalKey), isNull);
        stdout.writeln(
            'actual_dart_owner_restart_terminal_receipt_and_persisted_history=true');
      } else {
        expect(phase, 'backend-restart');
        expect(settled, isFalse);
        expect(owner.pending, isTrue);
        expect(owner.problem, contains('landed'));
        expect(owner.problem, contains('unproven'));
        expect(await secrets.read(journalKey), isNotNull);
        await expectLater(owner.send('no replay'), throwsStateError);
        stdout.writeln(
            'actual_backend_process_restart_exact_stored_metadata_unknown_no_replay=true');
      }
    }
  },
      skip: rootPath == null ? 'Run via official restart probe' : false,
      timeout: const Timeout(Duration(seconds: 70)));
}
