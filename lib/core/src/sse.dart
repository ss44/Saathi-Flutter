import 'dart:convert';

/// SSE framing, independent of transport chunk and UTF-8 scalar boundaries.
Stream<({String event, String data})> decodeEvents(
    Stream<List<int>> bytes) async* {
  var event = '';
  final data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield (event: event, data: data.join('\n'));
      event = '';
      data.clear();
      continue;
    }
    if (line.startsWith(':')) continue;
    final split = line.indexOf(':');
    final field = split < 0 ? line : line.substring(0, split);
    var value = split < 0 ? '' : line.substring(split + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') event = value;
    if (field == 'data') data.add(value);
  }
  if (data.isNotEmpty) yield (event: event, data: data.join('\n'));
}
