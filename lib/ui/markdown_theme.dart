import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Shared display colors for local replies and original-server history.
/// Rendering policy (including blocked images) remains with each caller.
MarkdownStyleSheet saathiMarkdownStyle(BuildContext context) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    a: TextStyle(
      color: colors.primary,
      decoration: TextDecoration.underline,
      decorationColor: colors.primary,
    ),
    // The dependency's legacy primaryColor can be a dark surface, not an accent.
    checkbox: TextStyle(color: colors.primary),
    code: theme.textTheme.bodyMedium!.copyWith(
      fontFamily: 'monospace',
      color: colors.onSurface,
      backgroundColor: colors.surfaceContainerLow,
    ),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: colors.outlineVariant),
    ),
  );
}
