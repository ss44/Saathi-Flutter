import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class ActivityTransportEvent {
  const ActivityTransportEvent(this.data, this.cursor);
  final Map<String, Object?> data;
  final String? cursor;
}

/// Canonical Runs SSE only. Caller supplies discovered capability and a current
/// connection/revision authority check. No polling, retries, or owned HTTP client.
/// Listen for errors AND done: either requires authoritative reconciliation.
class ActivityTransport {
  ActivityTransport(
      {required this.origin,
      this.profile,
      required String bearerKey,
      required this.isCurrent,
      required this.eventsSupported,
      required this.client,
      this.idleTimeout = const Duration(seconds: 60),
      this.maxLine = 16384,
      this.maxFrame = 65536})
      : _key = bearerKey {
    final loopback = origin.host == 'localhost' ||
        origin.host == '127.0.0.1' ||
        origin.host == '::1';
    if (!origin.hasAuthority ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        !(origin.scheme == 'https' || (origin.scheme == 'http' && loopback)) ||
        (profile != null &&
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(profile!)) ||
        bearerKey.isEmpty ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(bearerKey) ||
        idleTimeout <= Duration.zero ||
        maxLine < 1 ||
        maxFrame < maxLine) {
      throw ArgumentError('Unsafe activity configuration');
    }
  }
  final Uri origin;
  final String? profile;
  final bool Function() isCurrent;
  final bool eventsSupported;
  final http.Client client;
  final int maxLine, maxFrame;
  final Duration idleTimeout;
  String _key;
  String? _cursor;
  String? get cursor => _cursor;
  Completer<void>? _abort;
  Future<void>? _running;
  bool _closed = false;

  void _check() {
    if (_closed ||
        !eventsSupported ||
        !isCurrent() ||
        (_abort?.isCompleted ?? false)) {
      throw StateError('Activity authority unavailable');
    }
  }

  /// One subscription per connect. Reconnect is explicit, same configured scope.
  Stream<ActivityTransportEvent> connect(String runId, {String? lastEventId}) {
    _check();
    if (_abort != null) throw StateError('Activity stream already open');
    if (!RegExp(r'^run_[A-Za-z0-9_-]{1,240}$').hasMatch(runId) ||
        (lastEventId != null &&
            !RegExp(r'^[0-9]{1,20}$').hasMatch(lastEventId))) {
      throw ArgumentError('Invalid run identity or cursor');
    }
    final cancellation = Completer<void>();
    _abort = cancellation;
    _cursor = lastEventId;
    late StreamController<ActivityTransportEvent> out;
    out = StreamController<ActivityTransportEvent>(onListen: () {
      if (cancellation.isCompleted || !identical(_abort, cancellation)) {
        out.addError(StateError('Activity attachment aborted'));
        unawaited(out.close());
        return;
      }
      _running = _pump(runId, lastEventId, out).whenComplete(() {
        _running = null;
        _abort = null;
      });
    }, onCancel: () {
      if (!cancellation.isCompleted) cancellation.complete();
    });
    return out.stream;
  }

  Future<void> _pump(String runId, String? last,
      StreamController<ActivityTransportEvent> out) async {
    StreamIterator<String>? input;
    final cancellation = _abort!;
    final stop = cancellation.future;
    Future<T> guarded<T>(Future<T> future) async {
      _check();
      final result = await Future.any<T>(
          [future, stop.then<T>((_) => throw StateError('Activity aborted'))]);
      _check();
      return result;
    }

    try {
      _check();
      final path =
          '${profile == null ? '' : '/p/$profile'}/v1/runs/$runId/events';
      final request = http.AbortableRequest('GET', origin.replace(path: path),
          abortTrigger: stop)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $_key',
          'Accept': 'text/event-stream',
          if (last != null) 'Last-Event-ID': last
        });
      final response =
          await guarded(client.send(request).then((response) async {
        try {
          if (cancellation.isCompleted) throw StateError('Activity aborted');
          _check();
        } catch (_) {
          await response.stream.listen((_) {}).cancel();
          rethrow;
        }
        return response;
      }).timeout(idleTimeout));
      if (response.statusCode != 200 ||
          response.headers['content-type']
                  ?.split(';')
                  .first
                  .trim()
                  .toLowerCase() !=
              'text/event-stream') {
        await response.stream.listen((_) {}).cancel();
        throw StateError('Activity response rejected');
      }
      input = StreamIterator(
          response.stream.timeout(idleTimeout).transform(utf8.decoder));
      var line = StringBuffer(), data = <String>[];
      var size = 0;
      String? id;
      var afterCr = false;
      void finishLine() {
        final text = line.toString();
        line = StringBuffer();
        if (text.isEmpty) {
          if (data.isNotEmpty) {
            final decoded = jsonDecode(data.join('\n'));
            if (decoded is! Map<String, dynamic> ||
                decoded['run_id'] != runId ||
                decoded['event'] is! String ||
                (decoded['seq'] != null &&
                    (decoded['seq'] is! int || (decoded['seq'] as int) < 0))) {
              throw const FormatException('Invalid activity envelope');
            }
            _check();
            if (id != null) _cursor = id;
            // Whitelist observable activity only: no hidden reasoning/tool bodies.
            const allowed = {
              'event',
              'run_id',
              'seq',
              'timestamp',
              'subagent_id',
              'child_session_id',
              'delegation_id',
              'parent_id',
              'goal',
              'summary',
              'status',
              'task_count',
              'task_index',
              'depth',
              'model',
              'tool_count',
              'duration_seconds',
              'input_tokens',
              'output_tokens',
              'api_calls',
              'cost_usd'
            };
            out.add(ActivityTransportEvent(
                Map.unmodifiable({
                  for (final e in decoded.entries)
                    if (allowed.contains(e.key) &&
                        (e.value == null ||
                            e.value is String ||
                            e.value is num ||
                            e.value is bool))
                      e.key: e.value
                    else if (decoded['event'] == 'message.delta' &&
                        e.key == 'delta' &&
                        e.value is String)
                      e.key: e.value
                }),
                _cursor));
          }
          data = [];
          id = null;
          size = 0;
          return;
        }
        if (text.startsWith(':')) return;
        final colon = text.indexOf(':');
        final field = colon < 0 ? text : text.substring(0, colon);
        var value = colon < 0 ? '' : text.substring(colon + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        if (field == 'data') data.add(value);
        if (field == 'id') {
          if (!RegExp(r'^[0-9]{1,20}$').hasMatch(value)) {
            throw const FormatException('Invalid activity cursor');
          }
          id = value;
        }
      }

      while (await guarded(input.moveNext())) {
        for (final unit in input.current.codeUnits) {
          _check();
          if (afterCr && unit == 10) {
            afterCr = false;
            continue;
          }
          afterCr = false;
          if (++size > maxFrame) {
            throw const FormatException('Activity frame too large');
          }
          if (unit == 10 || unit == 13) {
            finishLine();
            afterCr = unit == 13;
          } else {
            line.writeCharCode(unit);
            if (line.length > maxLine) {
              throw const FormatException('Activity line too large');
            }
          }
        }
      }
      throw StateError('Activity stream disconnected');
    } catch (_) {
      // Do not forward network/parser exception text (may contain payload/key).
      if (!out.isClosed) {
        out.addError(
            StateError('Activity stream unavailable; reconcile run status'));
      }
    } finally {
      if (!cancellation.isCompleted) cancellation.complete();
      if (input != null) unawaited(input.cancel());
      unawaited(out.close());
    }
  }

  /// Abort on background or lost authority. Caller may explicitly reconnect.
  Future<void> abort() async {
    if (!(_abort?.isCompleted ?? true)) _abort!.complete();
    await _running;
    _abort = null;
  }

  /// Permanent disposal; injected client remains caller-owned.
  Future<void> close() async {
    _closed = true;
    _key = '';
    await abort();
  }
}
