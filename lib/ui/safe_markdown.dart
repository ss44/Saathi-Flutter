import 'package:flutter/widgets.dart';

/// Untrusted Markdown must not trigger network requests or local image reads.
/// All image sources are blocked, including relative paths and file URIs.
Widget safeMarkdownImageBuilder(Uri uri, String? title, String? alt) =>
    const Text('[Image blocked: automatic loading is disabled]');
