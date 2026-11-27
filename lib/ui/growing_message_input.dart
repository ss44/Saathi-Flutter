import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A draft field that grows to twice its single-line height, then scrolls.
///
/// The caller retains draft ownership; rebuilding for activity or keyboard
/// changes never replaces the editing controller or the field's focus state.
class GrowingMessageInput extends StatelessWidget {
  const GrowingMessageInput({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onChanged,
    this.onSubmit,
    this.hasPhotos = false,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool hasPhotos;
  final ValueChanged<String> onChanged;

  /// Optional desktop submit callback triggered by Enter without Shift or Alt.
  ///
  /// Ignored on mobile platforms, when disabled, during active IME composition,
  /// on key repeat, or when the draft has neither text nor photos.
  final VoidCallback? onSubmit;

  static const _desktopPlatforms = {
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  };

  KeyEventResult _handleKeyEvent(BuildContext context, KeyEvent event) {
    if (!_desktopPlatforms.contains(Theme.of(context).platform) ||
        !enabled ||
        onSubmit == null) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed || keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final composing = controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent ||
        (controller.text.trim().isEmpty && !hasPhotos)) {
      return KeyEventResult.handled;
    }
    onSubmit!();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge!;
    // Match the normal, unfilled Material 3 field's vertical padding. Measure
    // the same scaled font as EditableText rather than fixing pixels/line count:
    // large text must receive twice *its* normal input height as well.
    const padding = EdgeInsets.symmetric(vertical: 8);
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    );
    final singleLineHeight = math.max(
      kMinInteractiveDimension,
      painter.preferredLineHeight + padding.vertical,
    );
    painter.dispose();
    return Focus(
      skipTraversal: true,
      canRequestFocus: false,
      onKeyEvent: (_, event) => _handleKeyEvent(context, event),
      child: TextField(
        key: const Key('composer'),
        controller: controller,
        enabled: enabled,
        style: style,
        minLines: 1,
        maxLines: null,
        textCapitalization: TextCapitalization.sentences,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Message Saathi',
          hintMaxLines: 1,
          border: InputBorder.none,
          contentPadding: padding,
          constraints: BoxConstraints(maxHeight: singleLineHeight * 2),
        ),
      ),
    );
  }
}
