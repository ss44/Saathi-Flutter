/// Secure, opt-in release updates. See docs/UPDATES.md for integration.
library;

/// Semver precedence with a separate monotonically increasing platform build.
class UpdateVersion implements Comparable<UpdateVersion> {
  UpdateVersion._(this.name, this.build, this._parts, this._pre);

  factory UpdateVersion.parse(String name, int build) {
    final match = RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(name);
    if (match == null || build < 1 || build > 2100000000) {
      throw const FormatException('Invalid update version or Android build');
    }
    final pre = match.group(4)?.split('.') ?? <String>[];
    for (final id in pre) {
      if (RegExp(r'^0[0-9]+$').hasMatch(id)) {
        throw const FormatException('Leading zero in prerelease identifier');
      }
    }
    return UpdateVersion._(name, build,
        [for (var i = 1; i <= 3; i++) BigInt.parse(match.group(i)!)], pre);
  }

  final String name;
  final int build;
  final List<BigInt> _parts;
  final List<String> _pre;
  bool get isPrerelease => _pre.isNotEmpty;

  @override
  int compareTo(UpdateVersion other) {
    for (var i = 0; i < 3; i++) {
      final comparison = _parts[i].compareTo(other._parts[i]);
      if (comparison != 0) return comparison;
    }
    if (_pre.isEmpty != other._pre.isEmpty) return _pre.isEmpty ? 1 : -1;
    for (var i = 0; i < _pre.length && i < other._pre.length; i++) {
      final numeric = RegExp(r'^[0-9]+$');
      final a =
          numeric.hasMatch(_pre[i]) ? BigInt.parse(_pre[i], radix: 10) : null;
      final b = numeric.hasMatch(other._pre[i])
          ? BigInt.parse(other._pre[i], radix: 10)
          : null;
      final comparison = a != null && b != null
          ? a.compareTo(b)
          : a != null
              ? -1
              : b != null
                  ? 1
                  : _pre[i].compareTo(other._pre[i]);
      if (comparison != 0) return comparison;
    }
    final preComparison = _pre.length.compareTo(other._pre.length);
    return preComparison != 0 ? preComparison : build.compareTo(other.build);
  }

  /// Both the version and Android versionCode must not regress.
  bool isNewerThan(UpdateVersion other) =>
      compareTo(other) > 0 && build > other.build;

  @override
  String toString() => '$name+$build';
}
