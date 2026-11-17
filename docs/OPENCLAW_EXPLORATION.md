# OpenClaw interactive exploration — issue 16

## Verdict: PARTIAL — transport GO; shipping integration NO-GO

A **real official Gateway**, not a Gateway-shaped fixture, completed native
pairing → model catalog → session creation/list/selection → send → streamed
assistant text → final → token reconnect → the same authoritative session.
A deliberately discarded admission response did not cause a second submission;
a second native observer correlated its exact run and history recovered its text.
The model upstream was an explicitly synthetic localhost echo, not paid inference.

Issue 16 is **not done**. The Flutter provider remains unsupported. No login-only
or read-only replacement is introduced. Parent owns shared chat UI integration;
this branch adds bounded Dart domain/storage foundations, not a finished Dart
WebSocket adapter, platform signer, pairing UI, or small-screen/device proof.

## Versions and primary evidence

Research performed November 16, 2026. Distinguish package labels from commit dates:

- Registry `openclaw` dist-tag resolved to **2026.11.4**. Actual CLI reports
  `OpenClaw 2026.11.4 (d843d6a)`; full build source is
  `d843d6af39a42cd3c30084edbeabeece732fd93a` (commit November 15, 2026).
- Package integrity (npm registry):
  `sha512-kSMzBc0fIWrW4DqneFEXL9FRboCZCQV22Edm6iFPqRaBexUeZp9huWNPVWLXmuSAQRezorPfrABkODqq65NOmw==`.
- Runtime actually exercised: Node **26.12.1**, protocol **4**,
  `@openclaw/fs-safe` **0.26.7**. Nothing installed globally.
- Current official main inspected at
  `4940240568f12255fb7e392357f5b741b742311c`
  (November 16, 2026). Main is **not** the exercised Gateway build.
- Official docs site direct reads returned HTTP 403. Public search returned the
  official client/scopes pages; full documents were recovered from the official
  repository's raw files at that exact main SHA, NOT from a third-party rewrite.
  Installed release docs and compiled sources were also inspected.

Primary references (use `/blob/<SHA>/<path>` in `openclaw/openclaw`):

| Path | Contract |
| --- | --- |
| `docs/gateway/clients.md` | Third-party clients, pairing, reconnect, scoped subscriptions |
| `docs/gateway/protocol/handshake.md` | Req/res/event frames, challenge timestamp, protocol 4, hello grants/capabilities |
| `docs/gateway/protocol/auth.md` | Token/password bootstrap, device grants, v3 proofs, revocation/upgrades |
| `docs/gateway/operator-scopes.md` | Scope implications and session/profile authorization |
| `docs/gateway/protocol/operator-methods.md` | `models.list` model inventory, not agent routing aliases |
| `docs/gateway/protocol/rpc-session-control.md` | Create/list/history/send/events; main's newer custody contract |
| `docs/web/control-ui/connect-and-pair.md` | Pairing operator interaction |
| `packages/gateway-client/src/device-auth.ts` | Exact `buildDeviceAuthPayloadV3` field order |
| `src/infra/device-identity.ts` | Ed25519 public-key fingerprint/device ID |

Canonical docs are `https://docs.openclaw.ai/gateway/clients`,
`https://docs.openclaw.ai/gateway/operator-scopes`, and
`https://docs.openclaw.ai/gateway/protocol/rpc-session-control`.
Pinned raw documents remain in ignored `spikes/openclaw/primary/` for inspection.

## Genuine contract

### Authentication, pairing and least privilege

1. Dial the configured original Gateway (remote WSS with normal certificate
   validation). Wait for `connect.challenge {nonce, ts}`; `ts` must be a
   non-negative integer. Never substitute phone time for a malformed challenge.
2. Persist a stable Ed25519 identity securely. Device ID is SHA-256 of the raw
   32-byte public key. Public key and signature use base64url.
3. Sign UTF-8 `v3|deviceId|clientId|clientMode|role|comma-joined scopes|signedAt|token|nonce|normalized platform|normalized deviceFamily`.
   The probe uses registered `webchat` ID/mode, `operator` role, and a narrow
   explicit origin allowlist. Flutter's `platform` value must match its signed
   proof. First RPC is `connect` with protocol min=max=4 and the signed device.
4. Bootstrap with the Gateway's shared token/password, NOT an invented user
   password endpoint. `PAIRING_REQUIRED` carries the exact request/device IDs.
   Pause and let the host operator review/approve that request; reconnect with a
   fresh challenge. No app-side pairing/admin scope is required to be paired.
5. Inspect `hello-ok.auth.scopes`; persist its device token **with its original
   source, device, client and role**, in OS secret storage. Reconnect uses the
   same device and approved scope set. An unchanged token's stored grant should
   not be narrowed merely because a socket negotiated fewer live scopes.

The controlled config explicitly sets
`gateway.nodes.pairing.autoApproveLocal=false`; manual pending-request approval
was exercised through the official **isolated** host `devices list/approve` CLI.
No pairing file was hand-edited; no dangerous auth flags/internal backend bypass
were used. The CLI's host authority is not a mobile client's authority.

Verified shared-secret chat grant: `operator.read` + `operator.write`;
`operator.write` already implies read, so explicit read is redundant, not an
additional privilege. No `operator.admin`, `operator.pairing`, approvals,
questions, node or management scope was requested by the chat socket.

**Important narrower-scope blocker:** `operator.read` +
`operator.sessions.write` paired and read the real catalog, but `sessions.create`
was rejected: **`Session-scoped access requires a verified user profile.`**
Zero inference requests occurred. Shared bootstrap/device pairing alone did not
establish the verified profile required for that own-work permission path.
Do not silently escalate to broad write; present that prerequisite and let an
operator deliberately choose an authorized connection/grant. Identity-bearing
profile bootstrap is not implemented or verified here.

### Real catalog and sessions

- `models.list {view:"configured", provider:"controlled", preparedOnly:true}`
  returned `models` rows with distinct `provider`, `id`, and `name`; selected
  reference was `controlled/echo`. These are actual model tuples, NOT
  compatibility `agent:*` targets. Never forward Gateway credentials to catalog
  upstream URLs. Availability is a server fact; a model row isn't paid-key proof.
- `sessions.create {agentId:"main", model:"controlled/echo", idempotencyKey,
  displayName}` returned authoritative `key`, `sessionId`, resolved provider/model
  and `runStarted:false`. No transcript copied from another backend.
- `sessions.list {limit:50}` contained that key.
  `sessions.messages.subscribe {key}` and
  `chat.history {sessionKey:key, limit:20}` selected the same authorized session.
  Subscriptions are socket-local and must be renewed after reconnect.
- `chat.send {sessionKey, message, idempotencyKey, deliver:false}` sends **only new
  input**, not a locally replayed transcript. Its `{runId,status:"started",
  messageSeq}` response is admission, not completion.
- `chat` events correlate exact source/session/run. `delta.message` is a growing
  replacement snapshot; `final` is authoritative terminal text. Render only
  visible text blocks, not reasoning/tool payloads. Per-run seq deduplicates;
  chat-only mode must not assume every intermediate agent sequence is delivered.
- A transport gap or disconnect revokes live authority. Reconnect explicitly,
  renew subscriptions, replace the local projection with `chat.history`, adopt
  exact `inFlightRun` only when supplied, and never guess an active run from the
  first roster row. Token invalidation, profile changes and permission denial
  require explicit recovery, not an auth-bypassing retry loop.

### Uncertain sends: limits of the proof

The probe intentionally discards the second send's RPC response at the client
correlator, waits until another established native observer sees that exact
submission/run ID, then drops the submitting socket. The observer sees final;
reconnected history retains the answer. Exactly **two** echo inference calls
served **two** distinct submitted inputs. No retry/replay occurred.

This proves authoritative same-session reconciliation with an independent exact
run observation, **not** general never-acknowledged receipt recovery for a lone
phone or a durable outbox across app death. Matching transcript text alone cannot
settle an uncertain local submission. Keep its original identity and show an
uncertain state; don't generate a new send identity.

Current main documents `chat-input-custody-v1`, `chat.history.inputRunIds`,
`inputReceipts` (`pending`/`consumed`, `consumedByEventId`) and compatibility
`inputConsumptions`. The exercised 2026.11.4 hello **did not advertise**
`chat-input-custody-v1`; its compiled history schema nevertheless accepts
`inputRunIds` and contains receipt projections. The probe therefore explicitly
queries that source-verified reader rather than assuming support from wire version.
The actual result for the exact lost-ACK input was **`inputReceipts: []` and
`inputConsumptions: []`**, despite independently observed admission/final/history.
Thus this build did not prove single-client exact consumed-receipt recovery;
the caller must keep that local submission uncertain rather than infer failure
or completion from matching text. Do NOT enable new queue/control behavior
based on protocol version 4 alone.
Missing receipts never establish non-delivery, and idempotency retention is bounded.

## Controlled runtime prerequisite found

Default workspace bootstrap failed before inference with
`FsSafeError: staged file publish failed`. A separate minimal official
`@openclaw/fs-safe` diagnostic isolated this to native exclusive publication:

```text
renameat2 RENAME_NOREPLACE: EINVAL
code: FS_SAFE_INTERNAL_RENAME_NOREPLACE_UNSUPPORTED
FsSafeError code: helper-unavailable
```

Ordinary root write/create and staged overwrite publication succeeded. This is a
specific filesystem/runtime prerequisite, not a protocol/auth failure. The echo
probe uses the documented `agents.defaults.skipBootstrap=true`, appropriate for
this empty tool-disabled test workspace. It does **not** patch fs-safe, turn off
its checks, or establish that a normal tool-using Gateway can initialize safely
on this filesystem. Test a supported filesystem before deploying such a host.
`fs_probe.mjs` intentionally exits nonzero when that prerequisite is absent.

## Owned Dart public API / integration boundary

`lib/openclaw/openclaw_domain.dart`:

- `OpenClawSource(connectionId,url)` validates credential-free WSS (only literal
  loopback/localhost WS allowed); object identity binds a configuration generation.
- `OpenClawAuthority(source).prepareConnect(challenge,loadCredentials,sign)`
  constructs the exact v3 proof and protocol-4 params. Rechecks one-way authority
  after the secret-read AND signing awaits. `revoke()` cannot be undone.
- `OpenClawModel.parseCatalog` preserves real provider/model identity; refuses
  an agents-shaped compatibility list.
- `OpenClawTurn` separates awaiting admission/admitted/streaming/final/error/
  aborted/uncertain. Exact source/session/run matching and deduplication prevent
  unrelated completion; snapshots replace text; gaps/disconnect never resend.
  A marked-uncertain turn has deliberately no text-matching settlement shortcut.

`lib/openclaw/openclaw_secrets.dart`:

- `OpenClawSecrets` defaults to existing `PlatformSecrets` (OS secure storage).
  Device public/private PKCS8 material and token/grant are stored together in a
  hashed slot bound to exact connection+URL+client+role. No preference/history
  writes. Delayed stale reads are rejected; denied/corrupt storage is not ignored.
- `OpenClawSecretRecord.withHelloToken` preserves unchanged-token grant metadata.
- **No Ed25519 key generation/signing implementation is supplied in Flutter.**
  The future transport must use an audited platform/Dart signer over the
  OS-stored material, verify the public/private key relationship, validate grants
  and hold source authority through every dial/write/response/subscription await.
  It must bound frames/deadlines, disable redirects/compression, fence old sockets,
  and never treat these helpers as a permission to enable the direct provider.

Tests exercise the Dart domain with controlled values and an injected secret
store. Actual Keychain/Keystore persistence, remote TLS, pairing prompts, process
restart/device recovery, approval/question UX and small-screen interaction are
**not verified**. No shared UI/core/provider files, pubspec or existing unsupported
states were changed. Parent's integrated full-suite/85% application coverage
check remains required; scoped coverage is not a substitute.
