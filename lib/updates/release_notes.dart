import 'dart:convert';
import 'update_version.dart';

/// Optional, untrusted display text. Never interpreted as Markdown or HTML.
class ReleaseNotes {
  ReleaseNotes(this.version, List<String> changes)
      : changes = List.unmodifiable(changes);
  final String version;
  final List<String> changes;

  static List<String> parseBody(Object? body) {
    if (body is! String) return const [];
    const start = '<!-- saathi-changes:start -->';
    const end = '<!-- saathi-changes:end -->';
    if (start.allMatches(body).length != 1 ||
        end.allMatches(body).length != 1) {
      return const [];
    }
    final a = body.indexOf(start) + start.length;
    final b = body.indexOf(end);
    if (b < a) return const [];
    final lines = const LineSplitter().convert(body.substring(a, b));
    final notes = <String>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (!line.startsWith('- ') || line.substring(2).trim().isEmpty) {
        return const [];
      }
      notes.add(line.substring(2).trim());
    }
    return List.unmodifiable(notes);
  }

  static List<ReleaseNotes> fromChangelog(String source) {
    final data = jsonDecode(source);
    if (data is! Map || data['schema'] != 1 || data['releases'] is! List) {
      return const [];
    }
    final notes = <ReleaseNotes>[];
    for (final entry in data['releases']) {
      if (entry is! Map ||
          entry['version'] is! String ||
          entry['changes'] is! List) {
        continue;
      }
      try {
        UpdateVersion.parse(entry['version'], 1);
        final changes = entry['changes'] as List;
        if (changes.every((c) => c is String && c.trim().isNotEmpty)) {
          notes.add(ReleaseNotes(entry['version'], changes.cast<String>()));
        }
      } on FormatException {/* Optional history must not affect updates. */}
    }
    return merge(notes, const []);
  }

  static List<ReleaseNotes> merge(
      List<ReleaseNotes> bundled, List<ReleaseNotes> remote) {
    final byVersion = <String, ReleaseNotes>{
      for (final note in bundled) note.version: note
    };
    for (final note in remote) {
      if (note.changes.isNotEmpty || !byVersion.containsKey(note.version)) {
        byVersion[note.version] = note;
      }
    }
    return byVersion.values.toList()
      ..sort((a, b) => UpdateVersion.parse(b.version, 1)
          .compareTo(UpdateVersion.parse(a.version, 1)));
  }
}
