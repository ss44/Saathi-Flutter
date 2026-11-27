import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'thinking_phrases.dart';

/// Decorative local copy, not reasoning or backend/tool telemetry.
/// [busy] must reflect a real outstanding request; remove on terminal errors.
class BusyThinking extends StatefulWidget {
  const BusyThinking({super.key, required this.busy, this.random, this.clock});
  final bool busy;
  final Random? random;
  final DateTime Function()? clock;
  @override
  State<BusyThinking> createState() => _BusyThinkingState();
}

class _BusyThinkingState extends State<BusyThinking>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final _bag =
      ThinkingShuffleBag(visibleThinkingPhrases, random: widget.random);
  late String _quip = _bag.next();
  Timer? _timer;
  Timer? _shimmerTimer;
  Timer? _elapsedTimer;
  late DateTime _startedAt;
  DateTime _now() => (widget.clock ?? DateTime.now)();
  String _elapsed = '0.0s';
  bool _reduced = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _startedAt = _now();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    _syncActivity();
  }

  @override
  void didUpdateWidget(covariant BusyThinking oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !oldWidget.busy) {
      _startedAt = _now();
      _elapsed = '0.0s';
    }
    _syncActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    setState(() => _foreground = foreground);
    _syncActivity();
  }

  void _syncActivity() {
    if (!widget.busy || !_foreground || _reduced) {
      _timer?.cancel();
      _timer = null;
      _shimmerTimer?.cancel();
      _shimmerTimer = null;
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
      _shimmer.reset();
      return;
    }
    if (_shimmerTimer == null) {
      // Leave a rest between sweeps so an idle wait doesn't repaint constantly.
      _shimmer.forward();
      _shimmerTimer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
        _shimmer.forward(from: 0);
      });
    }
    // Native status/stream rebuilds must not restart the phrase cadence.
    // Local waiting time, not a claim about server execution or progress.
    _elapsedTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      final seconds =
          max(0, _now().difference(_startedAt).inMilliseconds) / 1000;
      final elapsed = '${seconds.toStringAsFixed(1)}s';
      if (elapsed != _elapsed) setState(() => _elapsed = elapsed);
    });
    _timer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      setState(() => _quip = _bag.next());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _shimmerTimer?.cancel();
    _elapsedTimer?.cancel();
    _shimmer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.busy) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final quip = Text(
      '$_quip...',
      key: const Key('thinking-quip'),
      style: theme.textTheme.bodyLarge?.copyWith(
        fontStyle: FontStyle.italic,
        color: colors.onSurfaceVariant,
      ),
    );
    return Semantics(
      label: 'Waiting for reply',
      liveRegion: false,
      child: ExcludeSemantics(
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_reduced || !_foreground)
                  quip
                else
                  ValueListenableBuilder<double>(
                    valueListenable: _shimmer,
                    child: quip,
                    builder: (context, progress, child) {
                      // The highlight clears the text at both ends of a sweep.
                      final center = -1.5 + 3 * progress;
                      return ShaderMask(
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment(center - .45, 0),
                          end: Alignment(center + .45, 0),
                          colors: [
                            colors.onSurfaceVariant,
                            colors.onSurface,
                            colors.onSurfaceVariant,
                          ],
                        ).createShader(bounds),
                        child: child,
                      );
                    },
                  ),
                if (!_reduced)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(_elapsed,
                        key: const Key('thinking-elapsed'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: colors.onSurfaceVariant,
                        )),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A local shuffle bag, unrelated to model reasoning or tool progress.
class ThinkingShuffleBag {
  ThinkingShuffleBag(List<String> phrases, {Random? random})
      : _phrases = List.unmodifiable(phrases),
        _random = random ?? Random() {
    if (phrases.isEmpty || phrases.toSet().length != phrases.length) {
      throw ArgumentError('Expected a nonempty unique pool');
    }
  }
  final List<String> _phrases;
  final Random _random;
  final List<String> _bag = [];
  String? _last;

  String next() {
    if (_bag.isEmpty) {
      _bag.addAll(_phrases);
      _bag.shuffle(_random);
      if (_bag.length > 1 && _bag.last == _last) {
        final first = _bag.first;
        _bag[0] = _bag.last;
        _bag[_bag.length - 1] = first;
      }
    }
    return _last = _bag.removeLast();
  }
}
