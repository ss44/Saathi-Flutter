# Conversation organization integration contract

Owned components for issues #28 and #14 live in `lib/chat_organization/`. They deliberately do not own transport, `ChatController`, `ChatHome`, message history, native jobs or secrets. The shipped integration lives in `ChatController` and `ChatHome`; isolated component tests remain distinct from end-to-end app acceptance.

## State and storage

- Construct one `ChatOrganization(OrganizationStorage(store.preferences))` above the native drawer, `await load()`, listen for updates and dispose with the controller. Metadata uses the separate `saathi.organization.v1` key, so chat/history saves cannot strip it. A failed/corrupt load must block organization edits; do not replace the stored value with empty data.
- Use `ConversationIdentity(originalConnectionId, originalLocalChatId)` everywhere. `entry(identity).title(session.title)` is the display title for **both the app bar and local search/rows**. Do not rewrite messages, model, connection identity or native session identity on rename.
- `setArchived(identity, bool)` changes only local metadata. It has no cancel/delete/send callback. Keep archived sessions in controller/history/job observation; only filter recents. `ConversationOrganizationList` contains search plus an explicit Archived view with attention counts and Restore.
- All metadata commits are save-first. `saving` and `hasUnsavedChanges` must block unsafe sends/mutations until resolved. On write failure, the committed presentation stays unchanged and the exact candidate remains in memory; `error` explains `retrySave()`. Retry does storage only, never inference. Preference-cache compensation prevents a false disk write from becoming apparent saved state. Compensation is best effort, not a claim of atomic disk recovery.
- Writes are single-owner: overlapping new mutations are rejected, not silently merged. Serialize incoming completion reconciliation and retry it from the already-retained authoritative result after a pending write resolves. Never retry a model request because metadata saving failed.
- Read/write bounds: 1,000 conversation entries, 100 shared personas, 512 exact completion markers per chat, 256-character original/reply/persona IDs, 120-character display names, 80-character persona names, 16,000-character instructions and a 2 Mi-character serialized document. Bounds fail closed; no marker eviction that would turn an old replay into a new completion. Resource-limit recovery must be visible; no silent truncation.

## Truthful per-chat activity and unread replies

- Populate `ConversationRowData.state` separately for each original chat from observed request/job/queue state, not the currently selected global `busy` flag. `ConversationWorkState` preserves idle, queued, working, awaitingInput, failed, unknown and cancelled. `ConversationStatus` provides static icons plus everyday text and a distinct accessible unread icon. Working and unread may coexist. Never persist a stale decorative spinner as live backend state after restart.
- Only after an authoritative successful final answer call `await recordCompletion(originalIdentity, stableReplyId)`. A native operation/message identity or preassigned direct assistant-message ID must survive reply persistence/recovery; do not generate a fresh ID for replay. ACKs, partial chunks, failure, cancellation and unknown outcomes are **not** completions. Do not seed unread by replaying imported remote history.
- Wrap the **actual answer body** (not a padded list row) in `ForegroundReplyVisibility`. Supply a namespaced reply identity (e.g. `(identity, replyId)`), and `enabled` only when that original chat's transcript is selected and uncovered. Specifically disable for drawer opening/dragging and other covering local overlays. The widget additionally checks resumed lifecycle, current route, ancestor viewports, offstage and zero-opacity ancestors. It rechecks on real scrolling and lifecycle changes; there is no navigation/poll-based seen marker.
- `onVisible: () => organization.markReplyVisible(identity, replyId)` durably acknowledges only a known completion. Unknown completion IDs throw (so a visibility sentinel cannot permanently acknowledge a reply before its completion marker is saved). Rebuild sentinels on organization changes, and preferably enable them only for known unread completion IDs. Failed seen writes keep it unread until saved. No switch, drawer-open or background-poll handler should call this API. The owner's enabled condition must account for any non-route overlays/hidden tabs; geometry alone cannot discover arbitrary occlusion.

## Drawer integration

The shipped app (`ChatHome`) composes `ConversationActionRow` directly inside its
mixed local/server sidebar/drawer. `ConversationOrganizationList` remains an
exported standalone helper for callers that only need a local-only list. Keep the
real `Scaffold.drawer` on narrow viewports so edge-swipe navigation stays native.
Rows physically translate over a trailing **Archive/Edit** rail; a menu exposes
the same actions without swiping. `onSelect` is navigation only, never mark-seen.
`onEdit` calls:

```dart
showConversationEdit(
  context: context,
  organization: organization,
  identity: identity,
  fallbackInstructions: session.systemPrompt,
  policy: personaPolicyForOriginalChat,
  pendingReason: pendingReasonForOriginalChat,
);
```

The dialog has explicit Save/Cancel, displays current instructions and explains future-only behavior. A failed save retains its draft with storage-only retry. Cancel discards only that dialog's failed edit, never another failed completion write.

## Shared personas and accepted work

- `SharedPersona` is a reusable assistant role. More than one chat may reference the same entity. It is **not** a provider, account, profile or backend workspace. Create/edit is a nested small dialog, not a settings dashboard. Shared edits disclose affected conversation count and saved display names, and explicitly say their effect is shared.
- `PersonaEditPolicy.localInstructions` permits local instruction changes only. `serverOwned` and `importedReadOnly` deny persona changes while still allowing local display rename/archive. There is no fabricated native mutation endpoint, new-session transition or remote-history replay.
- `pendingReason(identity)` must inspect **all original chats**, including queued, popped/preparing, in-flight, uncertain and native admitted/awaiting work. Return a clear reason. Shared saves check every attached chat, including inactive ones, again at Save and storage retry. For direct non-widget `edit()` callers, supply `revalidatePersonaChange` to recheck the current policy/pending restriction at retry.
- At input acceptance, before queuing or awaiting credentials, call `captureInstructions(identity, fallback: originalSessionPrompt)`. Store that immutable `CapturedInstructions` (persona ID, revision, exact instructions) with the accepted item/prepared operation. Dispatch/recovery must use the captured instructions, not a new lookup or mutable shared persona. Persist those snapshots in the outbox/native operation's existing typed whitelist. The organization module does not own or rewrite those journals.
- Never apply local instruction overrides to an attached native session unless its actual native contract supports them. No verified native persona mutation exists in this baseline; native edits remain disabled rather than claiming success.

## Reported usage

`ReportedUsage.fromMetadata(message.metadata)` reads only actual normalized integer `promptTokens`, `completionTokens`, `totalTokens` fields (0–1,000,000,000). `toMetadata()` is the three-field persistence whitelist; do not save raw provider `usage`/`runtime` maps. `ReportedUsageLine` is a small expandable line below an answer and hides when unsupported. Optional `ConversationContextMetadata` distinguishes local retained message count from server-owned context; supply a model limit only from a verified contract. There are no token heuristics, percent-full bars, prices or extra requests.

**Core usage provenance is now fixed:** Anthropic translation in `lib/core/src/core.dart` preserves absent counters, accepts only actual bounded nonnegative integers, and does not synthesize a total from input/output. `test/organization_usage_core_test.dart` covers missing, partial, explicit zero, malformed and complete counters. The prior provider-protocol expectation for an invented total was replaced with an absence assertion.

## Verification and remaining boundaries

`test/chat_organization/` exercises exact completion dedupe/restart and source isolation, actual scroll/drawer/background/route/offstage visibility, false preference writes, retained save failures and Cancel ownership, shared persona capture/restriction/retry/disclosure, malformed/bounded storage, reported usage and real native drawer swipe/menu/archive/restore/search/edit at 390px and 360px/2× text with keyboard insets.

The actual integration now lives in `ChatController` and `ChatHome`:

- Controller owns one organization store for its lifetime, derives activity for every original chat, serializes completion/visibility writes, and retains authoritative replies across metadata failures. The visible retry is storage-only. A stable direct reply ID is allocated at acceptance; native replies retain `run-${operationKey}`. Persisted `authoritativeCompletion: true` is a narrowly whitelisted recovery marker, never attached to imported history or empty terminal output.
- `QueuedFollowup` captures the exact role, revision and instructions synchronously before dispatch or credential reads. The prepared Direct head uses the bounded `saathi.prepared-inputs.v1` whitelist: original chat/connection, source revision/type/URL, model/provider, input, stable reply ID, prepared/dispatched state and captured role/revision/instructions. No connection map, credential or raw provider metadata is persisted. A never-dispatched head restores held; a potentially dispatched head restores uncertain and is never automatically resent. Credential replacement gives Direct connections an authority revision; recovery refuses a changed source. FIFO followers remain explicitly in-memory, as the queue UI states. Cancelling a durable head or abandoning uncertain work is save-first and asynchronous.
- Native prepared operations persist immutable `capturedInstructions`, optional `personaId` and `personaRevision` alongside their already authoritative payload. Existing native persona mutation stays unavailable. Continuation still uses the server-owned identity and existing scheduler, never imported-history replay or an organization-specific send path.
- The existing mixed local/server native Drawer retains edge gestures, local message search and server caches. Local rows use the physical action rail and accessible menu. Archived view/Restore, display-title search and app-bar rename are live. Organization edits do not clear the composer. All organization selection uses the existing `select()` queue-pause boundary.
- Only actual answer Markdown is wrapped in the visibility sentinel. The owner disables it during drawer opening/dragging, and the sentinel additionally enforces foreground lifecycle, route and viewport visibility. Organization changes rebuild it; unknown IDs never acknowledge future completions.
- Shared role creation/attachment uses the nested Edit dialog. Save/retry checks every attached original chat, including inactive, queued, preparing, in-flight and uncertain work. Usage is shown only from reported normalized integers and survives history storage through an explicit whitelist. Unsupported percentages/prices remain absent.

App evidence lives in `test/organization_controller_integration_test.dart`, `test/organization_home_integration_test.dart`, `test/organization_native_integration_test.dart` and `test/organization_usage_core_test.dart`. `test/chat_stabilization_integration_test.dart` now adds native persona restriction, actual drawer rename/archive and draft-preservation assertions to its joint 360/390px, 2× text, keyboard, live-child/stream, approval and optimizer test. See `docs/CHAT_ORGANIZATION_INTEGRATION.md` for exact gates and integration-base ownership.

This does not verify an Android device, secure storage, native build or a deployed native persona API. No credentials, paid inference, commit, push, PR or build is required or performed here.
