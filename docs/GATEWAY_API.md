# Native gateway API — integration contract

## Bounded mobile connection slice

The actual drawer now has an explicit trusted-host invitation/import path and
uses this adapter for canonical Desktop/CLI session attachment, composer input,
streaming and authoritative same-session resync. See
[HERMES_DELIVERY_ACCEPTANCE.md](HERMES_DELIVERY_ACCEPTANCE.md) for the current
Hermes-first acceptance table, real controlled-WSS/process-restart evidence,
exact review boundary and remaining deployment/device gates. The historical
component provenance is retained in `CANONICAL_MOBILE_HANDOFF.md`. No test count
is an independent release approval or an API-key-to-native-grant broker. The low-level contract below
remains distinct from HTTP chat and Runs.

Import `package:saathi/gateway/hermes_gateway.dart`. Native Dart (`dart:io`), no new dependencies. This is **separate from SaathiCore HTTP chat**. Do not restore remote history into direct chat and call it attached.

## Supported Hermes path

`HermesGatewayClient(grantProvider: Future<GatewayGrant> Function(), requestTimeout: Duration)`:

- `connect()` performs a real WebSocket upgrade then JSON-RPC `runtime.describe`. Requires canonical `durable-admission-v1`; older standalone/legacy sidecar servers are deliberately rejected.
- `listSessions({bool stored = false, int limit = 50})` → `List<GatewaySession>` (`id`, `title`, `running`). Sends `session.list` with `scope: live|stored`; there is no fabricated offset/total.
- `attach(String sessionId)` → `GatewaySnapshot`. Explicit `session.resume` with `display_projection: true`; loads the authoritative transcript and subscribes to live events. Uses the server-resolved session ID, including compression lineage resolution. Snapshot: `sessionId`, `storedSessionId`, `messages: List<GatewayMessage>` (`role`, `text`), `running`, `needsUserAction`, `authorityEpoch`, `executionGeneration`.
- `submit(String text, {required String inputId, String? expectedSessionId, String? expectedProfileId})` → `GatewayRun`. Sends **only** `{session_id, text, input_id}`, never history, system prompt, or local model configuration. Caller supplies a stable unique per-input identity; admission receipt has its own distinct `admissionId`. A receipt is admission, **not successful completion**.
- `events: Stream<GatewayEvent>` exposes `type`, `sessionId`, `owned`, `text`, `state`. Only safe visible message and action-needed notifications are projected; reasoning, raw tool payloads, system messages, and server error bodies are not exposed.
- `state`, `states` report disconnected/connecting/connected/disposed. `disconnect()` detaches the transport, not the server session; `dispose()` releases resources. Reconnect is explicit `connect()` and requires a fresh grant. Never automatically resubmit an input.
- `refreshRun()` → `GatewayRun`: reads `prompt.receipt` for the last acknowledged admission, after explicitly reattaching its original session/profile. Reconciles terminal `completed`, `failed`, `cancelled`/`interrupted`, and unknown outcomes without another prompt upload.
- `replayEvents()` → `bool`: reads `session.events.since` using the attached snapshot's replay epoch/sequence; visible replay events are deduplicated. `false` or `needsResync == true` requires explicit `attach()` to reload the snapshot. Sending is blocked until resynchronized. Replay **never** means resubmitting input.
- `attached`, `run` are current local handles. Disconnect marks active work unknown; reconnect never restores input implicitly. `CanonicalChat` journals exact input/session/profile state in secure storage before dispatch, and recovers a lost ACK from exact native pending input identity plus read-only `prompt.receipt`. Exact persisted submission metadata proves landing, not an unproven terminal result. Unknown remains unknown; no prompt is replayed.
- `CanonicalChat.queueInput` persists a typed source/profile/session-scoped **device-owned, not-yet-sent** next-turn FIFO separately from its no-replay operation journal. This is not the server's durable admission queue. Controller restoration is held behind explicit Resume. Failed queue/history writes retry storage only. Completed FIFO heads are durably removed before the terminal journal is deleted. See [PENDING_MESSAGE_FLOW.md](PENDING_MESSAGE_FLOW.md) for bounded lost-ACK reconciliation, user-facing state and the remaining multi-admission handoff blocker.
- Native `control` and `decide` use advertised same-attachment generation/request identity for Guide/Correct/interrupt, approval and clarification. They never create a second inference. `ChatSession.canonicalProfileId` is immutable local authority; legacy unscoped rows are not silently aliased to a new profile.
- Native approval retains the advertised `command` separately from descriptive text. Affirmative choices require a nonempty, bounded, reviewable command preview; missing, raw-JSON, control-character or credential-like previews disable approval while an advertised denial remains available. This does not change the native advertised choice vocabulary or request body.
- Canonical live preview retains at most 256 Ki UTF-16 code units. Once that budget would be exceeded, later deltas are omitted with an explicit preview-limit notice until authoritative reconciliation clears the preview. Receipt/snapshot recovery remains active and never resends input. Ordinary Stop exposes a synchronous UI callback to pause queued followers before requesting interruption; explicit interrupt-then-queue remains a distinct action.

Structured transcript image/image_url blocks project to a safe blocked-image placeholder before empty-row filtering, in both snapshot and cursor-paged history. Image URLs, local paths, inline bytes and private reasoning blocks are not fetched or retained by this projection. Canonical row identity and typed public tool activity remain intact; no attachment preview or download capability is added.

GatewayRunState: queued/running/complete/failed/cancelled/unknown. Events from another admission or owner generation cannot settle this client's run. `owned: false` is observation, not acknowledgement of a local send. Message final text is a replacement/final body, not another delta to append.

## Authentication/bootstrap boundary (important)

`GatewayGrant(url: Uri, protocols: List<String>)` is a caller-provided **trusted connection grant**, not an API-server key. Every dial invokes `grantProvider` anew; no ticket is persisted/logged by the client.

Verified native bootstrap is `hermes gateway attach --json` on the **host**. It returns `url`, `protocols` and owner identity. Protocols contain `hermes-gateway-v1` and `hermes-gateway-ticket.<single-use-ticket>`. Pass the returned protocols unchanged; obtain a fresh grant for each reconnect. The command/control socket runs on the host, not on a phone. A loopback URL returned by the host is not reachable from a phone without a separately configured trusted tunnel/forwarder. An app cannot mint these private local grants with `API_SERVER_KEY`.

Remote dashboard URL/token/OAuth boundaries are distinct. An operator can supply an already authenticated, reachable `/api/ws` URL/grant through an existing deployment login integration. **This patch does not implement dashboard sign-in, OAuth, a ticket broker, SSH forwarding, or an insecure key-to-ticket conversion.** It therefore does not claim one-click live mobile login to an arbitrary installation. Use TLS or a trusted tunnel for remote credentials. Do not show credential-bearing URLs in the UI or save one-use tickets as permanent settings.

## Verified API discovery evidence

Inspected live official documentation and primary `NousResearch/hermes-agent` main source, pinned to commit `eaac327fac2c2db0b77ee143989d49b29a6f36cb` (2026-11-12 discovery). Sources:

- Official `https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server`, section foreign sessions: REST writes to Desktop/CLI-owned sessions are HTTP 409; use WebSocket `prompt.submit` on the shared session. Reducing **mobile upload** is supported by that design; it does not remove model context/token costs or guarantee a subscription-limit bypass.
- Official `https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-local-sessions`: shared session operator access, list/resume/receipts and runtime negotiation.
- Pinned repository `hermes_cli/web_server_boundary.py:156-171`: exact subprotocol names, one unambiguous ticket protocol.
- `gateway/run_api.py`, `hermes_cli/web_server_chat.py:204+`: native `/api/ws` redemption and remote auth gates. Core socket rejects native HTTP-ticket headers; HTTP bearer and native WS grants are not interchangeable.
- `apps/shared/src/node/gateway-client.ts:44-51`: host attach JSON grant shape and fresh single-use grant on every dial.
- `gateway/session_controls.py:556+`: actual `runtime.describe` fields/capabilities, not an invented connect/auth JSON envelope.
- `tui_gateway/contracts/canonical_sessions.py:69-85,152-219,242-280,328-368`: canonical resume/list/submit/events-since schemas. `session.resume` attaches; there is no invented `session.attach` call.
- `gateway/session_events.py:75-138`: JSON-RPC `{method: event, params: {type,session_id,payload,replay_epoch,seq,authority_epoch,execution_generation,admission_id}}` envelopes and replay gap semantics.
- `gateway/session_settlement_recovery.py:54+`, `tui_gateway/contracts/events.py:198-203,281-305`: message.complete success/error/interrupted outcomes. `prompt.submit` acknowledgement is not a final answer.
- `apps/shared/src/gateway-canonical.ts`: canonical snapshots retain content-based rows; display projection is explicitly requested. No hidden reasoning is needed to render a transcript.

Repository source URLs are `https://github.com/NousResearch/hermes-agent/blob/<commit>/<path>` using the pinned commit above. The discovery files outside this repository are only research scratch, not runtime dependencies.

## Transport safety

- `wss://` required for remote hosts. Cleartext `ws://` is allowed only for literal loopback IPs or `localhost`. URL user-info and fragments are rejected. Exactly one canonical protocol, no duplicate protocols and at most one nonempty ticket protocol; unknown protocol families are rejected.
- **All HTTP upgrade redirects are disabled**, including same-origin redirects. Verified the installed Dart SDK implementation (`lib/_http/websocket_impl.dart`, `WebSocket.connect`) follows ordinary HttpClient redirects by default; a regression test reproduced successful cross-origin redirection before the fix. The client now supplies a narrow custom HttpClient whose `openUrl` sets `followRedirects = false`, with ordinary certificate validation unchanged.
- The approved bounded WebSocket transport rejects cumulative unfinished messages above 3 MiB or 1024 data fragments before assembly, preserves legal fragmentation around nonempty control frames, disables compression, and refuses binary application messages. ACK/attach-racing event buffers remain bounded to 256. Servers advertising `session-transcript-v1` use oldest-order `session.transcript` cursor pages with `inline_images:false`, durable row deduplication and explicit reset handling. Paging stops on an empty page; a continuously changing read is explicitly bounded at 256 pages rather than silently truncating a claimed complete snapshot. See `BOUNDED_WEBSOCKET.md`.
- List request limit must be 1–200; server list windows larger than the requested limit are rejected. Request/dial deadlines are bounded by `requestTimeout` (default 30 seconds).
- Connection-attempt epochs cancel pending grants/dials on disconnect/dispose; stale socket callbacks cannot mutate a newer connection, and closed state streams cannot be reopened.

## OpenClaw

New OpenClaw native integration is deferred under the user's Hermes-first scope (issue #16). Its isolated component work is not part of this delivery and is not represented as verified by Hermes tests. No guessed compatibility endpoint or synthetic successful pairing result is enabled.

## Verification scope

Default tests use real controlled local WS/WSS and actual ChatHome/controller fixtures. Separate opt-in probes run the installed official authority, runtime API, persisted transcript/receipts and one-use WSS gate, replacing only agent execution with an explicit non-inferencing stub. The restart probe exercises distinct Dart child processes and actual backend SIGKILL/restart over the same database. See the current acceptance table for which behaviors have official versus fixture evidence. No user's gateway, session, approval or production credential was modified.
