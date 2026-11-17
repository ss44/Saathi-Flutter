import 'package:flutter/material.dart';

/// One transcript-scoped latest affordance, measured after scroll layout.
/// Replacing this owner revokes pending metrics callbacks on selection changes.
class TranscriptLatest extends StatefulWidget {
  const TranscriptLatest({
    super.key,
    required this.controller,
    required this.onJump,
    required this.onReaderInteraction,
    required this.onUpdate,
    required this.child,
  });

  final ScrollController controller;
  final VoidCallback onJump;
  final VoidCallback onReaderInteraction;
  final bool Function(ScrollUpdateNotification) onUpdate;
  final Widget child;

  @override
  State<TranscriptLatest> createState() => _TranscriptLatestState();
}

class _TranscriptLatestState extends State<TranscriptLatest> {
  bool visible = false;
  int revision = 0;

  void measure() {
    final generation = ++revision;
    final controller = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != revision ||
          !identical(controller, widget.controller)) {
        return;
      }
      final show = controller.hasClients &&
          controller.position.hasContentDimensions &&
          controller.position.viewportDimension > 0 &&
          controller.position.extentAfter >
              controller.position.viewportDimension;
      if (show != visible) setState(() => visible = show);
    });
  }

  @override
  Widget build(BuildContext context) {
    measure();
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        measure();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (event) {
          measure();
          return event is ScrollUpdateNotification
              ? widget.onUpdate(event)
              : false;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              onPointerDown: (_) => widget.onReaderInteraction(),
              onPointerSignal: (_) => widget.onReaderInteraction(),
              onPointerPanZoomStart: (_) => widget.onReaderInteraction(),
              child: widget.child,
            ),
            if (visible)
              Positioned(
                right: 8,
                bottom: 8,
                child: TextFieldTapRegion(
                  child: IconButton.filledTonal(
                    tooltip: 'Jump to latest',
                    onPressed: widget.onJump,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      semanticLabel: 'Jump to latest',
                    ),
                    constraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
