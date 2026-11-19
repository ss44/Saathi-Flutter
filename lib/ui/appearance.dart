import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-lifetime preference owner. Theme changes never recreate chat state.
class Appearance extends ChangeNotifier {
  Appearance(this.preferences) {
    _state = _states[preferences] ??= _AppearanceState(preferences);
    _state.addListener(_changed);
  }

  static const preferenceKey = 'saathi.appearance.v1';
  static final _states = Expando<_AppearanceState>();
  final SharedPreferences preferences;
  late final _AppearanceState _state;
  ThemeMode get mode => _state.mode;
  String? get error => _state.error;
  bool saving = false;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Accepted writes survive disposal. Replacement owners share committed state,
  /// never the optimistic preferences cache, and can accept a newer choice.
  Future<void> select(ThemeMode value) async {
    if (_disposed || saving) return;
    if (value == mode && error == null && _state.pending == 0) return;
    saving = true;
    _changed();
    try {
      await _state.select(value);
    } finally {
      saving = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _state.removeListener(_changed);
    super.dispose();
  }
}

/// Same-cache, same-isolate coordination; not a native storage transaction.
/// Primary writes may overlap across owners. Settlement/compensation is ordered
/// so a delayed old completion cannot roll back a newer acknowledged selection.
class _AppearanceState extends ChangeNotifier {
  _AppearanceState(this.preferences)
      : _committed = preferences.get(Appearance.preferenceKey);

  final SharedPreferences preferences;
  Object? _committed;
  int _accepted = 0;
  int _committedSelection = 0;
  int _mutation = 0;
  int pending = 0;
  Future<void>? _settling;
  String? error;

  ThemeMode get mode =>
      ThemeMode.values.firstWhere((value) => value.name == _committed,
          orElse: () => ThemeMode.system);

  Future<void> select(ThemeMode value) async {
    final selection = ++_accepted;
    final mutation = ++_mutation;
    final overlappedSettlement = _settling != null;
    pending++;
    var saved = false;
    try {
      saved = await preferences.setString(Appearance.preferenceKey, value.name);
    } catch (_) {
      // A throwing platform write can still have mutated durable storage.
    }

    Future<void> settle() async {
      if (saved && selection > _committedSelection) {
        _committed = value.name;
        _committedSelection = selection;
        error = null;
      }
      // A later primary or compensating write may have overtaken this write.
      // Reassert the latest acknowledged choice, not this owner's old snapshot.
      // Primary writes that overlap this repair will themselves settle here.
      final needsRepair =
          !saved || mutation != _mutation || overlappedSettlement;
      final restored = !needsRepair || await _restoreCommitted();
      if (!restored) {
        error =
            'Could not save appearance. Your previous choice is still active, but could change after restarting. Try again.';
      } else if (!saved && selection >= _committedSelection) {
        error =
            'Could not save appearance. Your previous choice is still active.';
      }
      pending--;
      notifyListeners();
    }

    // Do not seed an artificial pending future: the first settlement starts in
    // its caller's zone, including widget fake-async/real-async transitions.
    final previous = _settling;
    final settlement =
        previous == null ? settle() : previous.then((_) => settle());
    _settling = settlement;
    await settlement;
    if (identical(_settling, settlement)) _settling = null;
  }

  Future<bool> _restoreCommitted() async {
    _mutation++;
    try {
      // Preserve the exact raw type/absence, including decoded List<Object?>.
      // Setters repair the optimistic cache even if durability is unconfirmed.
      return await switch (_committed) {
        String value => preferences.setString(Appearance.preferenceKey, value),
        bool value => preferences.setBool(Appearance.preferenceKey, value),
        int value => preferences.setInt(Appearance.preferenceKey, value),
        double value => preferences.setDouble(Appearance.preferenceKey, value),
        List value => preferences.setStringList(
            Appearance.preferenceKey, value.cast<String>()),
        _ => preferences.remove(Appearance.preferenceKey),
      };
    } catch (_) {
      return false;
    }
  }
}

/// Shares the same preference owner with all routes, including Settings.
class AppearanceScope extends InheritedNotifier<Appearance> {
  const AppearanceScope(
      {super.key, required super.notifier, required super.child});

  static Appearance? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}

class AppearanceSetting extends StatelessWidget {
  const AppearanceSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceScope.of(context);
    if (appearance == null) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InputDecorator(
              decoration: const InputDecoration(labelText: 'Appearance'),
              child: DropdownButtonHideUnderline(
                  child: Semantics(
                      label: 'Appearance',
                      child: DropdownButton<ThemeMode>(
                          key: const Key('appearance-choice'),
                          value: appearance.mode,
                          isExpanded: true,
                          items: [
                            for (final mode in ThemeMode.values)
                              DropdownMenuItem(
                                  value: mode,
                                  child: Text(switch (mode) {
                                    ThemeMode.system => 'System',
                                    ThemeMode.light => 'Light',
                                    ThemeMode.dark => 'Dark',
                                  })),
                          ],
                          onChanged: appearance.saving
                              ? null
                              : (value) async {
                                  if (value != null) {
                                    await appearance.select(value);
                                  }
                                })))),
          const SizedBox(height: 8),
          Text(appearance.saving
              ? 'Saving appearance…'
              : 'System follows your device’s light or dark appearance.'),
          if (appearance.error case final error?)
            Text(error,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ]));
  }
}
