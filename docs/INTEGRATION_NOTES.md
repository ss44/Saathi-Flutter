# Integration notes — research, not yet implemented

## Hermes API

The [official Hermes API server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server/) exposes the agent and its toolset over HTTP. It documents bearer-token authentication, capability discovery at `GET /v1/capabilities`, REST session management under `/api/sessions`, and SSE streaming at `POST /api/sessions/{id}/chat/stream`. The documented event stream includes message deltas, tool events and terminal run status. The API server defaults to localhost, which is not remotely reachable from a phone without appropriate network setup.

Use capability discovery rather than assuming every server version supports every feature. The docs describe image input, but the exact session-chat image payload must be confirmed before implementation. Test approval, cancellation and disconnected-run recovery against the actual server version. Do not automatically retry a submission unless its idempotency and outcome are known. Credentials can grant powerful tool access; protect them, use HTTPS or a protected tunnel, and never silently approve actions.

These are initial research notes, not evidence of a successful connection. No server has been tested for Iris.

## Android share intake

[Android's sharing documentation](https://developer.android.com/develop/ui/compose/sharing/receive) describes intent filters and recommends allowing review and edits before use. A platform channel or generated native binding can bridge Android and Flutter; [Flutter's native interop docs](https://docs.flutter.dev/platform-integration/platform-channels) note that Pigeon is recommended for new projects, while low-level channels remain available. Decide the approach during the share workstream.

Treat all incoming intents and content URIs as untrusted. Plan for cold and warm launches, temporary URI permissions, multiple images, repeated shares, process interruptions and explicit cleanup. Do not overwrite an existing edited draft or auto-send. Validate content and stage it privately; establish size limits and backup/retention rules before implementation.
