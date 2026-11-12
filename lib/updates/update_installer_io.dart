import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'update_service.dart';

/// Native code remains authoritative for package, signer and versionCode checks.
Future<bool> installVerifiedAndroidUpdate(VerifiedUpdate update) async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    throw const UpdateException('Use the release page on this platform');
  }
  const channel = MethodChannel('saathi/updates');
  final path = await channel.invokeMethod<String>('getCacheDirectory');
  if (path == null || path.isEmpty || !Directory(path).isAbsolute) {
    throw const UpdateException('Invalid private update cache');
  }
  final directory = Directory(path);
  await directory.create(recursive: true);
  final canonical = await directory.resolveSymbolicLinks();
  final file = File(
      '$canonical/saathi-${update.offer.version.build}-${update.offer.sha256}.apk');
  final partial = File('${file.path}.part');
  var handedOff = false;
  try {
    // Never derive a filesystem path from a remote asset name.
    await partial.writeAsBytes(update.bytes, flush: true);
    final diskHash = await crypto.sha256.bind(partial.openRead()).first;
    if (await partial.length() != update.offer.size ||
        diskHash.toString() != update.offer.sha256) {
      throw const UpdateException('Cached artifact checksum mismatch');
    }
    await partial.rename(file.path);
    // The OS installer may still need the file after this method returns.
    await channel.invokeMethod<void>('installApk', {'path': file.path});
    handedOff = true;
    return true;
  } finally {
    if (await partial.exists()) await partial.delete();
    if (!handedOff && await file.exists()) await file.delete();
  }
}
