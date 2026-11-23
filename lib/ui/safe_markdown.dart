import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// Untrusted Markdown must not trigger network requests or local image reads.
/// All image sources are blocked, including relative paths and file URIs.
Widget safeMarkdownImageBuilder(Uri uri, String? title, String? alt) =>
    const Text('[Image blocked: automatic loading is disabled]');

/// Returns a validated web URI (`http` or `https`) without embedded credentials,
/// control characters, whitespace, or out-of-range ports, or `null` for relative
/// paths and unsafe schemes (`javascript:`, `file:`, etc.).
Uri? parseSafeMarkdownLink(String? href) {
  if (href == null) return null;
  final trimmed = href.trim();
  if (trimmed.isEmpty || RegExp(r'[\x00-\x1F\x7F\s]').hasMatch(trimmed)) {
    return null;
  }
  final schemeEnd = trimmed.indexOf('://');
  if (schemeEnd == -1) return null;
  final rawAuthority =
      trimmed.substring(schemeEnd + 3).split(RegExp(r'[/?#]')).first;
  if (rawAuthority.contains('@')) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    return null;
  }
  return uri;
}

/// Opens a previously validated web [uri] externally. Returns `false` if the
/// platform launcher declines or throws.
Future<bool> openSafeMarkdownUri(
  Uri uri, {
  Future<bool> Function(Uri)? launch,
}) async {
  final opener = launch ??
      (target) => launchUrl(target, mode: LaunchMode.externalApplication);
  try {
    return await opener(uri);
  } catch (_) {
    return false;
  }
}

/// Validates [href] with [parseSafeMarkdownLink] and opens it externally.
/// Returns `false` if rejected or if the platform launcher declined it.
Future<bool> openSafeMarkdownLink(
  String? href, {
  Future<bool> Function(Uri)? launch,
}) async {
  final uri = parseSafeMarkdownLink(href);
  if (uri == null) return false;
  return openSafeMarkdownUri(uri, launch: launch);
}
