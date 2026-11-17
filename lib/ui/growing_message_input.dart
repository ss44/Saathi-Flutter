import 'dart:math' as math;

import 'package:flutter/material.dart';

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
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

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
    return TextField(
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
    );
  }
}
