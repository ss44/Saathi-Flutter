# Integration notes

These notes distinguish documented contracts from locally tested behavior. Automated fixtures are not evidence of a live provider connection.

## Source client
The Sathi source was read from `ss44/sathi.ai`, commit `e6dfc2491628b3f6497895a89ca4f08edefd4717`. It now includes direct-model adapters, preliminary Hermes/OpenClaw adapters, and optional smart context buckets. Saathi reimplements suitable behavior in Dart, without changing or importing the DMS plugin's runtime.

## Hermes
Official reference: https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server

Discover capabilities at `GET /v1/capabilities`; supported session listing/history live under `/api/sessions`. A server-owned session can accept new input with its ID rather than repeatedly uploading client history. This reduces phone-to-server traffic, not necessarily the model's context tokens.

Critically, the current ordinary API routes refuse attempts to bind a session owned by another surface (Desktop/CLI/TUI/ACP/messaging) with HTTP 409 `permission_denied`. Sharing an open session needs gateway WebSocket attachment and `prompt.submit`, not replaying a transcript to `/v1/chat/completions` or an invented `/api/chat` endpoint. Browsing history is not the same capability as live attachment. A future gateway client must reconcile history plus live events, compression lineage, reconnects, run state, approvals, and concurrent-client ownership.

Never auto-retry an admitted turn without idempotency/outcome guarantees. Completion text alone is not proof of successful execution; honor failed/cancelled/incomplete terminal states.

## OpenClaw
Official references:
- https://docs.openclaw.ai/gateway/protocol/rpc-session-control
- https://docs.openclaw.ai/gateway/protocol/handshake
- https://docs.openclaw.ai/gateway/protocol/rpc-bootstrap-and-events

Native session control is a gateway RPC contract (`sessions.list`, `chat.history`, `chat.send`, session subscriptions and run events) with authentication/handshake and exact session identity. The old DMS adapter's `/v1/agents` and `session_id` assumptions are not sufficient evidence of that contract. An explicitly supported OpenAI-compatible chat endpoint can still be configured as such; it must not claim native session browsing, remote tool control, or live attachment.

## Direct-model connections
Provider request/response translation belongs in the Dart core. Keep API credentials outside serializable connection metadata. Direct-provider requests normally carry client-selected context; they do not magically create a cross-provider server session. Provider discovery can be limited by credentials/API availability. Do not hardcode stale model prices into cost claims.

## Android networking and storage
Release manifest includes network permission. Cleartext traffic is blocked except exact loopback names; a physical phone cannot use the computer's localhost. Use a reachable HTTPS endpoint or protected tunnel. Android device/emulator testing remains necessary. API keys use secure storage, while conversation preferences are ordinary local app data; do not market chat history as encrypted. Android backups are disabled to avoid restoring credential-dependent data incorrectly.

## Updates
See `UPDATES.md` for the executable release flow and remaining release configuration. Parent Android bridge uses `saathi/updates`, private cache-only FileProvider URIs, package/version/current-signer validation, and explicit OS installation consent. Platform source checks are not a compiled/native installer test. Release signing comes from ignored `android/key.properties`; absent keys must not fall back to debug production signing. Keep the same signing identity for updates.

Primary Android references:
- https://developer.android.com/reference/android/content/pm/PackageManager
- https://developer.android.com/reference/androidx/core/content/FileProvider

## Share intake (not implemented)
Text/images shared from other apps must become editable drafts, not auto-send. Treat content URIs as untrusted and plan for permissions, size/type limits, cold/warm launch, duplicate intents, cancellation, and cleanup. Native work is gated on device/emulator tests.
