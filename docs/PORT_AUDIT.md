# Sathi → standalone Saathi core port audit

## Provenance and inspection

Sathi source: `/opt/data/cache/scratch/sathi-source`, commit `e6dfc2491628b3f6497895a89ca4f08edefd4717`.
Read `AGENTS.md`, `.agents/agents.md`, `providers/providers.js`, all five provider JS modules, `providers/context.js`, `chatHistory.js`, and system-prompt defaults in `Sathi.qml`/`ChatBackendChat.qml` before implementing the corresponding slices.

The source is a QML/Dank Material Shell plugin, not a Flutter application. Its provider registry uses instance IDs independently of names and compound `instance|model` IDs. It includes OpenAI-compatible, Anthropic and Gemini request conversion; credential/model/filter/grounding configuration; bounded history preserving the first message; token/cost metadata; stateful Hermes/OpenClaw adapters; and an optional two-leg context-bucket router with summarization, retry/fallback, stable message IDs, LRU buckets and persistence batching.

**Protocol correction:** Sathi's `hermes.js` guesses `/api/agents` + `/api/chat`; its `openclaw.js` guesses `/v1/agents` + a session_id field on Chat Completions. These were not copied as official integrations. Native Hermes API server documentation and actual primary Python source were inspected instead. Native shared-session transport is separate under `lib/gateway`; see `GATEWAY_API.md` for its tested scope and missing mobile authentication/UI.

### Native Hermes schema verification (not just invented mock envelopes)

Reference documentation: `https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server` (retrieved during this audit).
Primary source: `https://github.com/NousResearch/hermes-agent/blob/eaac327fac2c2db0b77ee143989d49b29a6f36cb/gateway/platforms/api_server.py`.
The downloaded main-branch file was byte-compared with this pinned commit and matched.

- `_handle_list_sessions`, lines 2520–2571: accepts `limit`, `offset`, `source`, `include_children`; returns `{object: list, data: [...], limit, offset, has_more}`. This source currently uses **data**, not a `sessions` envelope. Pins may be backfilled beyond limit, so the client preserves the server's `has_more` rather than computing one from row count.
- `_session_response`, lines 2440–2472: projects id/source/title/model and usage/status metadata; does not expose full model_config/system prompts. `RemoteSession.data` retains these server-projected fields.
- `_handle_session_messages`, lines 2730–2763: returns `{object: list, session_id: resolved_id, data: [...], pagination: {limit, offset, order, returned}}`; compression lineage may change the resolved session ID. Explicit oldest-first paging is sent by this client. No total or has_more field is invented. Tool/multimodal rows remain raw JSON.
- Documentation explicitly says REST cannot bind a live CLI/TUI/Desktop/messaging-owned session: requests are refused with HTTP 409 permission_denied; genuine attachment uses the shared gateway WebSocket and `prompt.submit`.

Loopback test fixtures mirror these source envelopes and pagination fields. This is protocol/schema verification, **not a successful connection to a real Hermes installation**.

## Ported and exercised

| Area | Actual implementation | Verification |
| --- | --- | --- |
| Public integration API | `lib/core/saathi_core.dart`; early-written `CORE_API.md` | Imported by core tests; analyzer clean |
| Provider instances/config | Stable IDs, independent credentials/endpoints/type/grounding/filter, secret-free JSON by default, manual model registration | Serialization, multi-instance discovery, refresh, rename and reconfiguration tests |
| Model discovery | OpenAI/Hermes `/v1/models`; Anthropic `/v1/models`; Gemini `/v1beta/models`, generation-method filtering; comma-separated case-insensitive display filter; instance-scoped refresh removes stale models | Real HTTP loopback request/response tests |
| OpenAI-compatible chat | `/v1/chat/completions`, model→assistant conversion, dedicated system messages, normalized token usage and raw usage/runtime/Hermes terminal metadata | Payload assertions, bounded context, 401, 409, metadata tests |
| Anthropic chat | `/v1/messages`, system field, consecutive role merge, max_tokens=4096, all text blocks combined (not thinking blocks), usage | Loopback payload/response tests |
| Gemini chat | `models/{model}:generateContent`, model/user roles and same-role merge, system_instruction parts, per-instance googleSearch, all non-thought text parts combined, grounding/usage metadata | Loopback discovery/payload/response tests |
| Conversation | System prompt retained; prompt reset clears history; source-style first-plus-recent pruning; history restore/JSON; no persistence coupling; successful exchanges appended once | History assertions, failed request rollback, reset during an in-flight request |
| Raw chat | Explicit model ref supported; system entries extracted; no history side effects | Anthropic/Gemini/Hermes raw call tests |
| Streaming | OpenAI-compatible and native Hermes Chat Completions SSE; UTF-8/chunk/CRLF/multiline framing; comments and named tool progress ignored; usage-only chunks retained; terminal errors/cancelled rejected | Loopback split-byte Unicode, usage-only, truncate/error/cancel, subscription cancellation, idle deadline tests |
| Hermes inspection | Capabilities, paginated sessions, paginated message history; read-only; source-resolved session ID and raw tool rows preserved | Source-derived fixture tests, profile-prefix URL handling |
| Traffic isolation | No foreign session headers/IDs on app chat, remote inspection never mutates local chat; no source-style global provider key/model singleton | Request assertions and 409 failure leaves history unchanged |
| Transport security | HTTPS except explicit loopback HTTP; root query/userinfo/fragment rejected; redirects disabled; positive configurable JSON overall/header/stream-idle deadlines; response byte cap; abort signals; no retry; generic redacted transport/API errors | Security regressions, injected real http.Client ownership and loopback size/timeout tests |
| In-flight mutation | Reconfigure/remove/select rejected while a conversation is active; resets invalidate commits; endpoint/key/type replacement clears old local history and instance models | Controlled in-flight response and endpoint-change tests |

## Deliberately not ported / limits

- **Live existing-session attachment:** not implemented in this core. Read-only REST inspection is not live attachment. The separate gateway module implements shared-session transport with a caller-provided trusted connection grant, not a finished mobile sign-in flow. Do not restore an inspected remote transcript into app chat and label that as control of the original session.
- **OpenClaw source endpoints/stateful sessions:** explicitly unsupported by direct-provider core until native gateway integration is available. No guessed HTTP requests. Hermes app chat does not retain per-instance server session IDs either; it sends app-owned full-history requests.
- **Smart context buckets:** source algorithm was inventoried but not partially reimplemented behind a misleading toggle. Requires its own negotiation/summarization/fallback/cancellation and persistence tests; bounded linear context is functional now.
- **Provider model-list pagination:** direct provider discovery currently reads one response page. Native Hermes sessions/history expose explicit pagination. No claim to enumerate every remotely hosted model.
- **Anthropic/Gemini streaming:** explicit unsupported error instead of simulated/chunked nonstreaming. Nonstreaming requests are implemented/tested.
- **Source pricing table:** not ported as current prices. It is hardcoded and has overlapping model-prefix matches (e.g. gpt-4o vs mini). Usage metadata is retained; monetary estimates require an explicit maintained pricing source.
- **Persistence/crypto:** no DMS service APIs, XOR/base64 key obfuscation or disk storage in core. Secure persistence belongs to parent/UI. Exported config omits credentials unless explicitly requested.
- **Multimodal/tools:** direct core message input is text only. Remote transcript tool and structured content are preserved as raw rows, not executed locally. Gemini thought parts and Anthropic thinking blocks are not surfaced as answer text.
- **Gateway run lifecycle/approvals/tool execution controls:** not invented in direct chat. Hermes `length` terminal content is a usable incomplete answer and preserves its metadata; `error`/`cancelled` is not persisted as a success.
- **Streaming limit semantics:** requestTimeout bounds response headers and each idle byte read, not the duration of an actively progressing multi-minute answer. Total bytes remain bounded. Canceling the subscription aborts transport but is not a guarantee of canceling server-side model/tool execution.
- **No real backend smoke test:** all network execution was synthetic loopback traffic only, with synthetic prompts/credentials. No actual user secrets/prompts were sent. Backend authentication, model-specific behavior and remote deployments remain unverified.

## TDD and verification

Vertical test→red→implementation→green runs were performed for configuration, instance discovery, OpenAI conversation, Anthropic, Gemini, native Hermes reads, SSE, and security regressions. Additional cancellation/terminal regressions verify existing error behavior. Initial normal Flutter test hit a shared-build shader asset compiler failure; `--no-test-assets` avoided that unrelated desktop asset build and allowed real Dart tests to execute.

Latest core-only verification:

```text
/opt/data/tools/flutter/bin/flutter analyze --no-pub lib/core test/core
No issues found!

/opt/data/tools/flutter/bin/flutter test --no-test-assets test/core
+17: All tests passed!
```

Dart formatting was applied only to owned `lib/core` and `test/core`. No commits or worktrees were created. Parent owns pubspec/platform/rebrand; UI/storage and updates are separate owners.
