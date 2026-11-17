# Bounded native WebSocket connection

`lib/gateway/bounded_websocket.dart` exports:

```dart
Future<WebSocket> connectBoundedWebSocket(
  String url, {
  Iterable<String>? protocols,
  Map<String, dynamic>? headers,
  int maxMessageBytes = 1024 * 1024,
  int maxMessageFragments = 1024,
  Duration connectTimeout = const Duration(seconds: 15),
  SecurityContext? securityContext,
  Future<void>? cancelSignal,
});
```

Both native adapters can use this factory instead of `WebSocket.connect`.
This module does **not** wire either adapter/controller. Consumers own source
revocation, protocol authentication, application validation, completed-message
queues and the returned WebSocket/subscription lifetime. Independent security
review and native integration/official-server verification remain separate gates.
Passing these controlled-socket tests does not establish native release readiness.

## SDK defect and normalization contract

The installed Dart 3.13.7 implementation was inspected at
`/opt/data/tools/flutter/bin/cache/dart-sdk/lib/_http/websocket_impl.dart`.
Its SHA-256 is
`96533243c2e7997fd3c7473f83f84aaf4b3f776d767504fae1ac41d73b7c7a86`.
`_payload` is shared between data and controls; `_controlFrameEnd` consumes
previously buffered data as part of nonempty ping/pong processing. The exact
controlled diagnostic sends hex `02 02 01 02 89 01 63 80 02 03 04`:
nonfinal binary `[1,2]`, ping `[99]`, final continuation `[3,4]`.
Before normalization both direct SDK and guarded transport returned `[3,4]`.
The regression also exposed a wrong automatic pong containing earlier data:
`[1,2,99,0,255]` instead of the received ping's `[99,0,255]`.

The inbound detached-socket adapter now withholds DATA fragments, reserves
aggregate bytes and fragment count from their declarations, and concatenates
only their payload bytes. After FIN it supplies a single equivalent final
text/binary frame to the official SDK, using the original message opcode and
exact original payload. Empty messages remain empty messages. There is no
application decoding/re-encoding. Split multibyte UTF-8 reaches the SDK intact.

Control frames are independently collected in at most 127 bytes and passed
promptly with **their original header and payload unchanged**, including while
a data message is unfinished. They never wait for DATA FIN, reset its accounting,
or get replaced with empty controls. The SDK alone handles ping replies, pong
liveness, close code/reason, outgoing masking and UTF-8 validation. On Close,
unfinished data is discarded and no subsequent data is supplied to the SDK.

Primary protocol reference: RFC 6455 sections 5.2, 5.4, 5.5.2–5.5.3 and 5.6
(`https://www.rfc-editor.org/rfc/rfc6455.txt`). Without negotiated extensions,
fragment boundaries do not carry application semantics; concatenated fragments
represent the same message. Controls must retain their contents and be processed
without waiting for the remaining message. This transformation is restricted to
the extension-free connection it creates; it is not a general WebSocket proxy.

## Validation, allocation and resource boundaries

- A fresh owned `HttpClient` is supplied using public SDK
  `WebSocket.connect(customClient:)`. The actual upgrade request has
  `followRedirects = false`; compression is `compressionOff`. The SDK's
  independent per-data-frame `maxPayloadLength` equals `maxMessageBytes`.
  HTTP upgrade nonce/accept checks and TLS remain official SDK operations.
- Three narrow HTTP adapters expose only SDK `openUrl`, request `headers`/`close`,
  and response `statusCode`/`headers`/`detachSocket`. Unknown operations fail
  closed. Recheck these exact SDK call sites on SDK upgrades.
- Partial headers span TCP chunks using at most ten retained bytes. Before body
  allocation the normalizer rejects masked server frames, any RSV bit, reserved
  opcodes, invalid continuation/new-message sequences, fragmented or oversized
  controls, nonminimal extended lengths, and lengths exceeding the message cap.
  Unsigned 64-bit high-bit/overflow declarations cannot wrap signed arithmetic:
  each multiplication is preceded by a bound comparison. Malformed wire is never
  repaired into a valid DATA frame. Close contents/UTF-8 remain SDK-validated.
- Each initial data frame and continuation reserves its declared bytes and one
  fragment **before allocation**. Empty frames count, including the final frame;
  controls do not count. FIN resets the counters only after its entire payload.
  An oversized declaration disconnects without requiring its body.
- One geometrically grown typed data buffer holds unfinished DATA, with capacity
  at most `maxMessageBytes`. Growth may transiently hold both old and new buffers
  (less than twice the configured cap). No per-TCP-chunk payload list is retained.
  A final frame header is at most ten bytes; the final payload uses a view of the
  owned buffer. The SDK can retain that completed payload and allocate its own
  message/UTF-8 result. This is not a one-copy or whole-process heap guarantee.
- Normalized output is yielded incrementally through the socket stream. SDK
  pause/resume propagates to the underlying subscription; there is no eager
  completed-message output queue in the normalizer. A current raw TCP chunk may
  remain retained while paused. Controls are prompt when inbound reading is
  active, not a guarantee to bypass a caller/SDK-paused receive stream.
- Guard rejection, stream error/EOF and cancellation destroy the raw socket and
  release guard buffers. Cancellation before async generator startup is handled
  explicitly. Active cancellation starts before microtask-scheduled destruction
  to avoid synchronous SDK iterator re-entry; destruction never waits for a
  paused iterator's cancellation future. EOF never emits unfinished DATA.
- Connection failure, timeout or pre-success cancellation force-close the owned
  HTTP client and any detached socket. The original SDK future remains observed;
  a late successful socket is closed/destroyed rather than orphaned. Cancellation
  future errors are observed as connection failures.
- On success the detached socket transfers to the returned WebSocket. The HTTP
  client closes without forcing that detached socket closed. Later cancellation
  signal completion has no effect; callers close/cancel their WebSocket.
- Default OS trust and hostname validation remain enabled. Optional
  `SecurityContext` supports explicit private/test roots; there is no trust-all
  callback, new masking/crypto implementation, dependency, or SDK edit.

The caps bound one inbound data message and its fragment metadata, including a
never-finished message. They do not limit traffic rate, connection count,
completed-message SDK/application queues, caller-retained history, TCP/HTTP/TLS
buffers or total process memory. Choose caps appropriate to each consumer.

## Focused verification

```sh
/opt/data/tools/flutter/bin/flutter test --no-pub test/gateway/bounded_websocket_test.dart
/opt/data/tools/flutter/bin/dart analyze --fatal-infos lib/gateway/bounded_websocket.dart test/gateway/bounded_websocket_test.dart test/gateway/fixtures/sdk_control_interleave_probe.dart
/opt/data/tools/flutter/bin/dart format --output=none --set-exit-if-changed lib/gateway/bounded_websocket.dart test/gateway/bounded_websocket_test.dart test/gateway/fixtures/sdk_control_interleave_probe.dart
```

Default tests use real local HTTP-upgraded sockets, including nonempty interleaved
ping/pong, exact automatic pong **before final data is sent**, split multibyte
UTF-8/binary payloads, multiple messages, empty messages, split headers, 125-byte
ping with a one-byte data cap, paused consumer resumption, aggregate byte and
zero-length fragment floods, invalid framing in whole/split chunks, oversized
64-bit declarations without bodies, exact extended-length bounds, cleanup on EOF,
Close during unfinished data, paused receive cancellation, protocol/headers,
compression off, TLS trust/rejection, cross-authority redirect refusal, bad
handshake accept, and connect timeout/cancellation ownership.

The original upstream diagnostic remains opt-in, not a default failing test:

```sh
/opt/data/tools/flutter/bin/dart run test/gateway/fixtures/sdk_control_interleave_probe.dart
```

Expected diagnostic on the inspected SDK (exit **1** because direct SDK is broken):

```text
direct official SDK diagnostic message=[3, 4]; RFC expected=[1, 2, 3, 4]
normalized transport message=[1, 2, 3, 4]; RFC expected=[1, 2, 3, 4]
```

The factory no longer exposes that upstream message-truncation limitation.
The diagnostic's exit status is not the default transport acceptance result.

`localhost-test-cert.pem` and `localhost-test-key.pem` are intentionally public,
synthetic localhost-only TLS test fixtures, valid 2020–2040. They are not
production credentials and must not be used outside tests. Default tests require
no openssl/Python process, production keys or paid endpoint calls.
