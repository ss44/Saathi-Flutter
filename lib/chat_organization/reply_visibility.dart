import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Wrap the actual completed answer, not its list row/spacer. The owner must set
/// enabled only for the selected transcript with no drawer/overlay covering it.
/// Route and app lifecycle checks are additional guards, never inferred from a
/// poll, chat switch or build. onVisible must durably save before completing.
class ForegroundReplyVisibility extends StatefulWidget {
  const ForegroundReplyVisibility(
      {super.key,
      required this.replyIdentity,
      required this.enabled,
      required this.onVisible,
      required this.child});
  final Object replyIdentity;
  final bool enabled;
  final Future<void> Function() onVisible;
  final Widget child;
  @override
  State<ForegroundReplyVisibility> createState() =>
      _ForegroundReplyVisibilityState();
}

class _ForegroundReplyVisibilityState extends State<ForegroundReplyVisibility>
    with WidgetsBindingObserver {
  ScrollPosition? _position;
  bool _scheduled = false, _reported = false, _reporting = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_schedule);
      _position = position;
      _position?.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(ForegroundReplyVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replyIdentity != widget.replyIdentity) _reported = false;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _schedule();
  void _schedule() {
    if (_scheduled || _reported || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _check();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _check() async {
    if (!mounted ||
        _reported ||
        _reporting ||
        !widget.enabled ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    var visible = box.localToGlobal(Offset.zero) & box.size;
    var painted = true;
    // Intersect every ancestor viewport: nested scrolling must not count an
    // answer painted outside an outer viewport as seen.
    context.visitAncestorElements((element) {
      final render = element.findRenderObject();
      if (render is RenderOffstage && render.offstage) painted = false;
      if (render is RenderOpacity && render.opacity == 0) painted = false;
      if (render is RenderAbstractViewport && render is RenderBox) {
        final viewport = render as RenderBox;
        if (viewport.hasSize) {
          visible = visible
              .intersect(viewport.localToGlobal(Offset.zero) & viewport.size);
        }
      }
      return true;
    });
    visible = visible.intersect(Offset.zero & MediaQuery.sizeOf(context));
    if (!painted || visible.width < 20 || visible.height < 8) return;
    _reporting = true;
    final identity = widget.replyIdentity;
    try {
      await widget.onVisible();
      if (mounted && identity == widget.replyIdentity) _reported = true;
    } catch (_) {
      // Owner exposes retained save failure/retry. Do not spin or resend input.
    } finally {
      _reporting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return widget.child;
  }

  @override
  void dispose() {
    _position?.removeListener(_schedule);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
