import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import 'update_version.dart';

class UpdateConfig {
  const UpdateConfig(
      {this.owner = '',
      this.repo = '',
      this.channel = 'stable',
      this.distribution = 'standalone'});

  factory UpdateConfig.fromEnvironment() => const UpdateConfig(
        owner: String.fromEnvironment('SAATHI_UPDATE_OWNER'),
        repo: String.fromEnvironment('SAATHI_UPDATE_REPO'),
        channel: String.fromEnvironment('SAATHI_UPDATE_CHANNEL',
            defaultValue: 'stable'),
        distribution: String.fromEnvironment('SAATHI_DISTRIBUTION',
            defaultValue: 'standalone'),
      );

  final String owner, repo, channel, distribution;
  bool get enabled =>
      distribution == 'standalone' &&
      RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$').hasMatch(owner) &&
      RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}$').hasMatch(repo) &&
      (channel == 'stable' || channel == 'beta');
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Only created after repository, release, channel and manifest validation.
class UpdateOffer {
  const UpdateOffer._(
      {required this.version,
      required this.channel,
      required this.platform,
      required this.releaseUrl,
      required this.assetUrl,
      required this.assetName,
      required this.size,
      required this.sha256});
  final UpdateVersion version;
  final String channel, platform, assetName, sha256;
  final Uri releaseUrl, assetUrl;
  final int size;
}

/// Bytes only become installable after exact size and SHA-256 verification.
class VerifiedUpdate {
  VerifiedUpdate._(this.offer, Uint8List bytes)
      : bytes = bytes.asUnmodifiableView();
  final UpdateOffer offer;
  final Uint8List bytes;
}

class SaathiUpdateService {
  SaathiUpdateService(
      {required this.config,
      required this.installed,
      http.Client? client,
      this.platform = 'android'})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const maxDownloadBytes = 150 * 1024 * 1024;
  static const maxManifestBytes = 64 * 1024;
  final UpdateConfig config;
  final UpdateVersion installed;
  final String platform;
  final http.Client _client;
  final bool _ownsClient;
  final Set<UpdateOffer> _issuedOffers = {};

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Checks up to 30 recent published GitHub releases. No credentials required.
  Future<UpdateOffer?> check() async {
    if (!config.enabled) return null;
    final endpoint = Uri.https('api.github.com',
        '/repos/${config.owner}/${config.repo}/releases', {'per_page': '30'});
    final bytes = await _read(endpoint, limit: 1024 * 1024, metadata: true);
    final releases = jsonDecode(utf8.decode(bytes));
    if (releases is! List || releases.length > 30) {
      throw const UpdateException('Invalid release list');
    }
    UpdateOffer? newest;
    for (final item in releases) {
      final release = _map(item);
      if (release['draft'] != false || release['prerelease'] is! bool) continue;
      if (config.channel == 'stable' && release['prerelease'] == true) continue;
      final assets = release['assets'];
      if (assets is! List) {
        throw const UpdateException('Missing release assets');
      }
      final manifestName = 'saathi-update-${config.channel}.json';
      final manifests =
          assets.where((a) => a is Map && a['name'] == manifestName).toList();
      if (manifests.isEmpty) continue;
      if (manifests.length != 1) {
        throw const UpdateException('Ambiguous manifest');
      }
      final tag = _text(release, 'tag_name');
      // This also forbids tags containing encoded paths, credentials or traversal.
      if (!RegExp(r'^v[0-9A-Za-z.+-]+$').hasMatch(tag)) {
        throw const UpdateException('Invalid release tag');
      }
      final releaseUrl = _repoUri(['releases', 'tag', tag]);
      if (!_sameUrl(_text(release, 'html_url'), releaseUrl)) {
        throw const UpdateException('Release belongs to another repository');
      }
      final meta = _map(manifests.single);
      final manifestUrl =
          _validateAsset(meta, tag, manifestName, maxManifestBytes);
      final manifestBytes = await _read(manifestUrl, limit: maxManifestBytes);
      if (manifestBytes.length != meta['size']) {
        throw const UpdateException('Manifest size mismatch');
      }
      _checkDigest(meta, crypto.sha256.convert(manifestBytes).toString());
      final manifest = _map(jsonDecode(utf8.decode(manifestBytes)));
      if (manifest['schema'] is! int ||
          manifest['schema'] != 1 ||
          manifest['channel'] != config.channel ||
          manifest['platform'] != platform) {
        throw const UpdateException(
            'Unsupported manifest, channel or platform');
      }
      final build = manifest['build'];
      if (build is! int) throw const UpdateException('Invalid build number');
      final version = UpdateVersion.parse(_text(manifest, 'version'), build);
      if (tag != 'v${version.name}' ||
          (config.channel == 'stable' && version.isPrerelease)) {
        throw const UpdateException('Release version/channel mismatch');
      }
      final asset = _map(manifest['asset']);
      final assetName = _text(asset, 'name');
      if (!_safeAssetName(assetName) ||
          (platform == 'android' && !assetName.endsWith('.apk'))) {
        throw const UpdateException('Invalid artifact name');
      }
      final size = asset['size'];
      final hash = _text(asset, 'sha256');
      if (size is! int ||
          size < 1 ||
          size > maxDownloadBytes ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const UpdateException('Invalid artifact size or checksum');
      }
      final matches =
          assets.where((a) => a is Map && a['name'] == assetName).toList();
      if (matches.length != 1) {
        throw const UpdateException('Missing or ambiguous artifact');
      }
      final assetMeta = _map(matches.single);
      final assetUrl =
          _validateAsset(assetMeta, tag, assetName, maxDownloadBytes);
      if (size != assetMeta['size'] ||
          !_sameUrl(_text(asset, 'url'), assetUrl)) {
        throw const UpdateException('Artifact metadata mismatch');
      }
      _checkDigest(assetMeta, hash);
      if (!version.isNewerThan(installed)) continue;
      final offer = UpdateOffer._(
          version: version,
          channel: config.channel,
          platform: platform,
          releaseUrl: releaseUrl,
          assetUrl: assetUrl,
          assetName: assetName,
          size: size,
          sha256: hash);
      if (newest == null || version.compareTo(newest.version) > 0) {
        newest = offer;
      }
    }
    if (newest != null) _issuedOffers.add(newest);
    return newest;
  }

  Future<VerifiedUpdate> download(UpdateOffer offer,
      {void Function(double)? onProgress}) async {
    validateOffer(offer);
    final bytes =
        await _read(offer.assetUrl, limit: offer.size, onProgress: onProgress);
    if (bytes.length != offer.size) {
      throw const UpdateException('Artifact size mismatch');
    }
    if (crypto.sha256.convert(bytes).toString() != offer.sha256) {
      throw const UpdateException('Artifact checksum mismatch — not installed');
    }
    return VerifiedUpdate._(offer, bytes);
  }

  void validateOffer(UpdateOffer offer) {
    if (!config.enabled ||
        !_issuedOffers.contains(offer) ||
        offer.channel != config.channel ||
        !offer.version.isNewerThan(installed)) {
      throw const UpdateException('Untrusted or obsolete update offer');
    }
  }

  Uri _repoUri(List<String> segments) => Uri(
      scheme: 'https',
      host: 'github.com',
      pathSegments: [config.owner, config.repo, ...segments]);

  Uri _validateAsset(
      Map<String, dynamic> meta, String tag, String name, int limit) {
    final size = meta['size'];
    final expected = _repoUri(['releases', 'download', tag, name]);
    if (meta['state'] != 'uploaded' ||
        size is! int ||
        size < 1 ||
        size > limit ||
        !_sameUrl(_text(meta, 'browser_download_url'), expected)) {
      throw const UpdateException('Unsafe or invalid release asset');
    }
    return expected;
  }

  Future<Uint8List> _read(Uri initial,
      {required int limit,
      bool metadata = false,
      void Function(double)? onProgress}) async {
    // A total deadline supplements per-chunk idle deadlines.
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    var uri = initial;
    for (var redirects = 0; redirects <= 3; redirects++) {
      if (!_https(uri)) throw const UpdateException('HTTPS required');
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['Accept'] =
          metadata ? 'application/vnd.github+json' : 'application/octet-stream';
      if (metadata) request.headers['X-GitHub-Api-Version'] = '2022-11-28';
      final response =
          await _client.send(request).timeout(const Duration(seconds: 30));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        // Cancel instead of draining a potentially unbounded redirect response.
        await response.stream.listen((_) {}).cancel();
        final location = response.headers['location'];
        if (metadata || location == null || redirects == 3) {
          throw const UpdateException('Unexpected update redirect');
        }
        final next = uri.resolve(location);
        final trustedCdn =
            next.host == 'release-assets.githubusercontent.com' ||
                next.host == 'objects.githubusercontent.com';
        if (!_https(next) || (!trustedCdn && next != initial)) {
          throw const UpdateException('Unsafe update redirect');
        }
        uri = next;
        continue;
      }
      if (response.statusCode != 200 ||
          (response.contentLength != null && response.contentLength! > limit)) {
        await response.stream.listen((_) {}).cancel();
        throw const UpdateException(
            'Update unavailable or response exceeds size limit');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        if (DateTime.now().isAfter(deadline) ||
            builder.length + chunk.length > limit) {
          throw const UpdateException('Update exceeds time or size limit');
        }
        builder.add(chunk);
        onProgress?.call(builder.length / limit);
      }
      return builder.takeBytes();
    }
    throw const UpdateException('Too many redirects');
  }
}

bool _https(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    (!uri.hasPort || uri.port == 443) &&
    !uri.hasFragment;
bool _sameUrl(String raw, Uri expected) {
  final parsed = Uri.tryParse(raw);
  return parsed != null &&
      _https(parsed) &&
      !parsed.hasQuery &&
      parsed.host == expected.host &&
      parsed.pathSegments.join('\u0000') ==
          expected.pathSegments.join('\u0000');
}

bool _safeAssetName(String name) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) &&
    !name.contains('..');
Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const UpdateException('Invalid update metadata');
  }
  return value;
}

String _text(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw UpdateException('Missing update field: $key');
  }
  return value;
}

void _checkDigest(Map<String, dynamic> meta, String expected) {
  if (meta['digest'] != null && meta['digest'] != 'sha256:$expected') {
    throw const UpdateException('GitHub asset checksum mismatch');
  }
}
