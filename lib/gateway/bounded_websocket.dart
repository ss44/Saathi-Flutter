import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Connects with the SDK handshake, TLS verification and WebSocket parser.
///
/// Enforces incoming message bytes and data-frame count before allocation,
/// including unfinished messages. DATA fragments are normalized to one final
/// frame before the SDK parser; control headers/payloads pass promptly unchanged.
/// Compression and redirects are disabled.
/// [securityContext] may add a test/private CA; certificate verification is never
/// bypassed. Owns a fresh HTTP client; callers own the returned WebSocket and must
/// close it. Timeout, cancellation and failed upgrades destroy owned resources.
/// [cancelSignal] cancels only connection establishment, not a returned socket.
Future<WebSocket> connectBoundedWebSocket(
  String url, {
  Iterable<String>? protocols,
  Map<String, dynamic>? headers,
  int maxMessageBytes = 1024 * 1024,
  int maxMessageFragments = 1024,
  Duration connectTimeout = const Duration(seconds: 15),
  SecurityContext? securityContext,
  Future<void>? cancelSignal,
}) async {
  if (maxMessageBytes < 1 ||
      maxMessageFragments < 1 ||
      connectTimeout <= Duration.zero) {
    throw ArgumentError('Bounds and timeout must be positive');
  }
  final client = _UpgradeClient(
    HttpClient(context: securityContext),
    maxMessageBytes,
    maxMessageFragments,
  );
  final result = Completer<WebSocket>();
  void fail(Object error, [StackTrace? stack]) {
    if (result.isCompleted) return;
    client.dispose();
    result.completeError(error, stack);
  }

  final timer = Timer(
      connectTimeout,
      () => fail(
          TimeoutException('WebSocket connect timed out', connectTimeout)));
  if (cancelSignal != null) {
    unawaited(cancelSignal.then(
        (_) => fail(const WebSocketException('WebSocket connect cancelled')),
        onError: (Object error, StackTrace stack) => fail(error, stack)));
  }
  // Observe the original operation even if a timeout/cancellation wins the race.
  unawaited(Future<WebSocket>.sync(() => WebSocket.connect(
        url,
        protocols: protocols,
        headers: headers,
        compression: CompressionOptions.compressionOff,
        maxPayloadLength: maxMessageBytes,
        customClient: client,
      )).then((socket) {
    if (result.isCompleted) {
      client.dispose();
      unawaited(socket.close().catchError((Object _) {}));
    } else {
      client.inner.close(); // Detached socket is now owned by the WebSocket.
      client.socket = null;
      result.complete(socket);
    }
  }, onError: (Object error, StackTrace stack) => fail(error, stack)));
  try {
    return await result.future;
  } finally {
    timer.cancel();
  }
}

// Deliberately narrow SDK adapters: fail closed if the SDK starts using another
// HttpClient/Request/Response operation. No reflective forwarding or handshake
// duplication. Recheck these three adapters when upgrading the SDK.
class _UpgradeClient implements HttpClient {
  _UpgradeClient(this.inner, this.bytes, this.fragments);
  final HttpClient inner;
  final int bytes;
  final int fragments;
  Socket? socket;
  bool disposed = false;
  void dispose() {
    disposed = true;
    socket?.destroy();
    inner.close(force: true);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _UpgradeRequest(await inner.openUrl(method, url), this);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'Unsupported SDK HTTP client operation: ${invocation.memberName}');
}

class _UpgradeRequest implements HttpClientRequest {
  _UpgradeRequest(this.inner, this.owner) {
    if (owner.disposed) {
      inner.abort();
      throw const WebSocketException('Connection cancelled');
    }
    inner.followRedirects = false;
  }
  final HttpClientRequest inner;
  final _UpgradeClient owner;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  Future<HttpClientResponse> close() async =>
      _UpgradeResponse(await inner.close(), owner);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'Unsupported SDK HTTP request operation: ${invocation.memberName}');
}

class _UpgradeResponse implements HttpClientResponse {
  _UpgradeResponse(this.inner, this.owner);
  final HttpClientResponse inner;
  final _UpgradeClient owner;
  Future<Socket>? detached;
  @override
  int get statusCode => inner.statusCode;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  Future<Socket> detachSocket() => detached ??= _detach();
  Future<Socket> _detach() async {
    final socket = await inner.detachSocket();
    owner.socket = socket;
    if (owner.disposed) socket.destroy();
    return _BoundedSocket(socket, owner.bytes, owner.fragments);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'Unsupported SDK HTTP response operation: ${invocation.memberName}');
}

class _BoundedSocket extends Stream<Uint8List> implements Socket {
  _BoundedSocket(this.inner, int bytes, int fragments)
      : guard = _MessageGuard(bytes, fragments);
  final Socket inner;
  final _MessageGuard guard;
  Stream<Uint8List> _incoming() async* {
    try {
      await for (final chunk in inner) {
        // Yield incrementally: a control never waits for the data message FIN.
        // async* propagates SDK pauses without queuing normalized messages.
        for (final normalized in guard.normalize(chunk)) {
          yield normalized;
        }
      }
    } finally {
      guard.release();
      inner.destroy();
    }
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    late StreamSubscription<Uint8List> subscription;
    late StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        subscription = _incoming().listen(controller.add,
            onError: controller.addError, onDone: controller.close);
      },
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () {
        // An async* finally does not run if cancelled before its body starts.
        // Cancel first, then destroy after the current data callback unwinds:
        // synchronous destroy can re-enter the SDK's active StreamIterator.
        // Do not wait for cancellation before destroy: a paused iterator may
        // need EOF to complete its cancellation.
        final cancelled = subscription.cancel();
        scheduleMicrotask(inner.destroy);
        return cancelled;
      },
    );
    return controller.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  void add(List<int> data) => inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => inner.addStream(stream);
  @override
  Future<void> flush() => inner.flush();
  @override
  Future<void> close() => inner.close();
  @override
  Future<void> get done => inner.done;
  @override
  void destroy() => inner.destroy();
  @override
  Encoding get encoding => inner.encoding;
  @override
  set encoding(Encoding value) => inner.encoding = value;
  @override
  void write(Object? object) => inner.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => inner.writeln(object);
  @override
  InternetAddress get address => inner.address;
  @override
  InternetAddress get remoteAddress => inner.remoteAddress;
  @override
  int get port => inner.port;
  @override
  int get remotePort => inner.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => inner.setRawOption(option);
}

// Narrow inbound framing normalizer, not a handshake/control/UTF-8 replacement.
// Never expose partial data to the SDK: its shared data/control payload builder
// otherwise consumes earlier data on a nonempty interleaved ping or pong.
class _MessageGuard {
  _MessageGuard(this.maxBytes, this.maxFragments);
  final int maxBytes;
  final int maxFragments;
  final List<int> header = [];
  int remaining = 0;
  int messageBytes = 0;
  int written = 0;
  int fragments = 0;
  int messageOpcode = 0;
  int frameOpcode = 0;
  bool fin = false;
  bool closed = false;
  Uint8List payload = Uint8List(0);
  Uint8List control = Uint8List(0);
  int controlWritten = 0;
  Never reject() => throw const WebSocketException(
      'Invalid frame or WebSocket message bound exceeded');

  Iterable<Uint8List> normalize(Uint8List chunk) sync* {
    var offset = 0;
    while (offset < chunk.length && !closed) {
      if (remaining > 0) {
        final available = chunk.length - offset;
        final consumed = available < remaining ? available : remaining;
        if (frameOpcode >= 8) {
          control.setRange(
              controlWritten, controlWritten + consumed, chunk, offset);
          controlWritten += consumed;
        } else {
          payload.setRange(written, written + consumed, chunk, offset);
          written += consumed;
        }
        remaining -= consumed;
        offset += consumed;
        if (remaining == 0) yield* finish();
        continue;
      }
      header.add(chunk[offset++]);
      if (header.length < 2) continue;
      final marker = header[1] & 127;
      final needed = marker == 127 ? 10 : (marker == 126 ? 4 : 2);
      if (header.length < needed) continue;
      frameOpcode = header[0] & 15;
      fin = header[0] & 128 != 0;
      final isControl = frameOpcode >= 8;
      // No extensions are negotiated; masked server frames are always invalid.
      if (header[0] & 112 != 0 ||
          header[1] & 128 != 0 ||
          ![0, 1, 2, 8, 9, 10].contains(frameOpcode) ||
          (isControl && (!fin || marker > 125))) {
        reject();
      }
      var length = marker < 126 ? marker : 0;
      if (marker >= 126) {
        if (marker == 127 && header[2] & 128 != 0) reject();
        for (var i = 2; i < needed; i++) {
          // Compare before arithmetic to reject overflow and oversize headers
          // without allocating or waiting for any body bytes.
          if (length > maxBytes ~/ 256) reject();
          length = length * 256 + header[i];
          if (length > maxBytes) reject();
        }
        if (marker == 126 ? length < 126 : length < 65536) reject();
      }
      if (!isControl) {
        if (frameOpcode == 0 ? messageOpcode == 0 : messageOpcode != 0) {
          reject();
        }
        if (length > maxBytes - messageBytes || fragments >= maxFragments) {
          reject();
        }
        if (frameOpcode != 0) messageOpcode = frameOpcode;
        messageBytes += length;
        fragments++;
        // Geometric growth avoids a per-TCP-chunk retained allocation/list node.
        // Capacity never exceeds the byte cap. Reservations precede allocation.
        if (messageBytes > payload.length) {
          final doubled = payload.length > maxBytes - payload.length
              ? maxBytes
              : payload.length * 2;
          final capacity = doubled > messageBytes ? doubled : messageBytes;
          final grown = Uint8List(capacity);
          grown.setRange(0, written, payload);
          payload = grown;
        }
      } else {
        control = Uint8List(needed + length)..setRange(0, needed, header);
        controlWritten = needed;
      }
      remaining = length;
      header.clear();
      if (remaining == 0) yield* finish();
    }
  }

  void release() {
    payload = Uint8List(0);
    control = Uint8List(0);
    header.clear();
  }

  Iterable<Uint8List> finish() sync* {
    if (frameOpcode >= 8) {
      final complete = control;
      control = Uint8List(0);
      if (frameOpcode == 8) {
        closed = true;
        payload = Uint8List(0); // An unfinished message cannot survive Close.
      }
      yield complete; // Original control header and payload, without rewriting.
    } else if (fin) {
      final bytes = Uint8List.sublistView(payload, 0, written);
      final out = <int>[128 | messageOpcode];
      if (written < 126) {
        out.add(written);
      } else if (written <= 65535) {
        out.addAll([126, written >> 8, written & 255]);
      } else {
        out.add(127);
        out.addAll((ByteData(8)..setUint64(0, written)).buffer.asUint8List());
      }
      payload = Uint8List(0);
      messageOpcode = 0;
      messageBytes = 0;
      written = 0;
      fragments = 0;
      yield Uint8List.fromList(out);
      if (bytes.isNotEmpty) yield bytes;
    }
  }
}
