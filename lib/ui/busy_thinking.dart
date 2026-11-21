import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
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
    with WidgetsBindingObserver {
  late final _bag =
      ThinkingShuffleBag(visibleThinkingPhrases, random: widget.random);
  late String _quip = _bag.next();
  Timer? _timer;
  Timer? _loader;
  Timer? _elapsedTimer;
  late DateTime _startedAt;
  DateTime _now() => (widget.clock ?? DateTime.now)();
  String _elapsed = '0.0s';
  double _turns = 0;
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
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant BusyThinking oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !oldWidget.busy) {
      _startedAt = _now();
      _elapsed = '0.0s';
    }
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncTimer();
  }

  void _syncTimer() {
    if (!widget.busy || !_foreground || _reduced) {
      _timer?.cancel();
      _timer = null;
      _loader?.cancel();
      _loader = null;
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
      return;
    }
    // Native status/stream rebuilds must not restart the phrase cadence.
    _loader ??= Timer.periodic(const Duration(milliseconds: 800), (_) {
      setState(() => _turns += .5);
    });
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Local waiting time, not a claim about server execution or progress.
      _elapsedTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        final seconds =
            max(0, _now().difference(_startedAt).inMilliseconds) / 1000;
        final elapsed = '${seconds.toStringAsFixed(1)}s';
        if (elapsed != _elapsed) setState(() => _elapsed = elapsed);
      });
    }
    _timer ??= Timer.periodic(
        Duration(
            seconds: defaultTargetPlatform == TargetPlatform.android ? 3 : 8),
        (_) {
      setState(() => _quip = _bag.next());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _loader?.cancel();
    _elapsedTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.busy) return const SizedBox.shrink();
    if (defaultTargetPlatform == TargetPlatform.android) {
      final colors = Theme.of(context).colorScheme;
      return Semantics(
        label: 'Waiting for reply',
        liveRegion: false,
        child: ExcludeSemantics(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              key: const Key('pending-response-bubble'),
              constraints: const BoxConstraints(maxWidth: 720),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_reduced || !_foreground)
                        Icon(Icons.hourglass_empty_rounded,
                            size: 18, color: colors.primary)
                      else
                        AnimatedRotation(
                          key: const Key('thinking-loader'),
                          turns: _turns,
                          duration: const Duration(milliseconds: 500),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                                value: .7,
                                strokeWidth: 2,
                                color: colors.primary),
                          ),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('$_quip...',
                            key: const Key('thinking-quip'),
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(
                                  fontStyle: FontStyle.italic,
                                  color: colors.primary.withValues(alpha: .5),
                                )),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(_elapsed,
                        key: const Key('thinking-elapsed'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
    return Semantics(
      label: 'Waiting for reply',
      liveRegion: false,
      child: ExcludeSemantics(
          child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_reduced || !_foreground)
            const Icon(Icons.hourglass_empty_rounded, size: 18)
          else
            AnimatedRotation(
              key: const Key('thinking-loader'),
              turns: _turns,
              duration: const Duration(milliseconds: 500),
              child: const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(value: .7, strokeWidth: 2),
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Waiting for reply'),
              const SizedBox(height: 4),
              Text('A little whimsy: $_quip',
                  key: const Key('thinking-quip'),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          )),
        ],
      )),
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
