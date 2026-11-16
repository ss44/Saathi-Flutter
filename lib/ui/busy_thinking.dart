import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'thinking_phrases.dart';

/// Decorative local copy, not reasoning or backend/tool telemetry.
/// [busy] must reflect a real outstanding request; remove on terminal errors.
class BusyThinking extends StatefulWidget {
  const BusyThinking({super.key, required this.busy, this.random});
  final bool busy;
  final Random? random;
  @override
  State<BusyThinking> createState() => _BusyThinkingState();
}

class _BusyThinkingState extends State<BusyThinking>
    with WidgetsBindingObserver {
  late final _bag =
      ThinkingShuffleBag(visibleThinkingPhrases, random: widget.random);
  late String _quip = _bag.next();
  Timer? _timer;
  bool _reduced = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
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
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncTimer();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (widget.busy && _foreground && !_reduced) {
      _timer = Timer.periodic(const Duration(seconds: 8), (_) {
        setState(() => _quip = _bag.next());
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.busy) return const SizedBox.shrink();
    return Semantics(
      label: 'Waiting for reply',
      liveRegion: false,
      child: ExcludeSemantics(
          child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.hourglass_empty_rounded, size: 18),
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
