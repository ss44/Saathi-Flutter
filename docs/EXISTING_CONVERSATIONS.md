# Existing server conversations — issue 38

## Source behavior

This follow-up builds on #60's native conversation integration and #71's authority
and recovery fixes. It is not a new adapter or a claim that a published build or
user device has passed acceptance.

- Selecting an API-owned conversation from the drawer, desktop sidebar or Settings
  history browser starts native continuation automatically. There is no default
  read-only landing step or **Continue conversation** action. The original history
  remains visible while checking/connecting; sending is enabled in the normal
  ChatHome only after the original owner is ready.
- Opening only reads history/capabilities and attaches. It never sends input.
  New input stays bound to the original connection/session and uses native Runs;
  the imported history is not uploaded as model context. Original model/provider
  metadata is retained. No persona/system-instruction setup screen or mutation is
  introduced (#73 owns contextual configuration).
- Initial Runs attachment reads oldest-first pages, advances using raw returned
  rows (including hidden/tool rows), validates pagination and exact session identity,
  and deduplicates explicit durable row IDs without collapsing repeated text.
  A missing `has_more` does not truncate a full page. A failed read installs no
  partial new chat; retry re-reads the original history without inference. The
  attachment window is bounded at 256 pages and fails rather than claiming a
  truncated history is complete. This is not a total history retention design.
- A previously attached local conversation retains its existing run journal,
  messages and uncertainty when opened again. Selection is not an acknowledgement
  of a pending run, approval, or unknown submission. Existing reconciliation/FIFO
  policy remains in force; opening never invokes admission recovery POSTs and
  cannot clear or bypass an outstanding save-first recovery warning.
- Source-map replacement, credential mutation at its start (including failed saves),
  route disposal and pause/resume revoke an in-progress open. Returning to the
  foreground does not revive a stale read or silently attach. Explicit retry can
  acquire fresh authority when that same connection is available.

## Conservative refresh policy

Reopening an already attached API session is **append-only reconciliation**, not
concurrent edit/delete conflict resolution. History is read from the exact
original connection. An idle transcript must remain unchanged across the read:
no accepted/preparing/queued input, uncertain/prepared journal or uncommitted run
may be present, and the same local message objects must still be in the list.

- Compare the complete projected remote history against every local row, in
  order, using its projected role and content. Equal history is a safe no-op.
  Only an exact prefix followed by additional remote rows can be appended.
- Keep all existing message objects, completion IDs and metadata. Imported rows
  are history, not newly completed replies: no invented completion, unread
  marker or reply notification. Retain original connection/session/model/provider,
  selected conversation, draft and transcript reader position.
- A shorter, edited or otherwise divergent idle history is an explicit
  `RemoteContinuationUnavailable` outcome. The opening page stays open with a
  specific explanation that local history was kept and cannot safely be combined;
  it does **not** close into an apparently refreshed, ready stale chat. No local
  rows are overwritten or deleted. The user can return with Back to retained
  local history, or review changes on the original host and use **Try connecting
  again**. Retry reads the original history afresh; it succeeds only when that
  host again supplies equal history or an exact-prefix extension. Retry is not a
  force-overwrite/conflict-resolution action.
- If an idle local conversation changes while the GET is outstanding (including
  accepted input or a newer local answer), reject that refresh with a separate
  explanation and retain the newer state. Retry requires a fresh read. Selection
  round trips or original-source revocation reject the old operation even if the
  apparent selection returns.
- A conversation already pending or uncertain when opening began is not eligible
  for this refresh. Preserve its native journal/recovery owner and select its
  existing conversation; never interpret the imported rows as settlement or replay
  uncertain input. This correction does not change #37 recovery/thinking policy.
- An accepted append that fails storage remains in memory behind save-first
  recovery. **Try saving again** retries storage only, without another history
  GET, inference, completion or model/provider change.

## Native attachment route authority

Every app entry to `CanonicalConnectionPage` uses `CanonicalConnectionRoute`.
Its route-event callbacks irreversibly revoke an in-flight attachment's navigation
permission on coverage or completion/removal, including a synchronous cover
push/pop between frames, a dialog and a zero-duration route. Ordinary Material
route embedding also listens synchronously to route animation status; app callers
must use the dedicated route because not every cover animates its predecessor.
No global Navigator behavior is changed. A fresh explicit attachment attempt may
acquire fresh authority; returning to the old route never revives the old attempt.

Accepted history persistence still completes after Back/cancel, coverage,
selection or source revocation. The controller revalidates after that await,
suspends the revoked native attachment and refuses late `pop`/`popUntil`, leaving
Settings and any foreign covering route intact. Opening/reattaching submits no
prompt and never changes the original profile/session identity.

## Concrete boundaries and recovery

| Resource/state | Supported path or prerequisite |
| --- | --- |
| API-owned session with advertised Runs/idempotency/status support | Select → capability/history reads → original-session composer. |
| API key denied history access | Permission explanation; correct credentials/session access, then retry. No enabled sending or fallback endpoint. |
| Runs contract unavailable | Explain missing advertisement and operator enable/upgrade prerequisite; retain history and explicit retry. |
| Desktop/CLI/messaging history discovered through REST | API bearer access is not native continuation authority. **Connect to original host** opens the existing trusted WSS/fresh-invite path; the user selects the authorized native session there. No ID-only cross-protocol aliasing or transcript replay. |
| Connected native session list | Selecting the session uses existing `session.resume` and returns to the normal composer, including when reached through a history/settings route. |
| Locally saved canonical session after suspension/restart | Keep history in ChatHome, explain that a fresh original-host invite is required, and offer **Reconnect to original host**. With the explicit fresh invite, resume the saved session automatically, requiring its original connection and verified profile. No extra session/Continue selection and no input submission. |
| Legacy canonical row without a saved profile | Do not infer old authority from the newly connected profile. Explain the missing identity; explicitly select an authorized session through the native host list without reassigning legacy history. |
| Denied/unknown native attachment or different profile | Fail closed, retain original history/identity, explain original host/profile/session access and fresh-invite recovery. |
| OpenClaw native participation | Still deferred under #16/#66; no speculative adapter or endpoint is introduced. |

The canonical backend retains its live-session ownership, concurrent-client events,
controls, receipts and cursor-based transcript contract. This patch does not change
#37 thinking/recovery behavior or turn a native admission ACK into completion.

## Verification and remaining acceptance

Focused tests cover the actual drawer-to-composer path, narrow Runs UI with large
text/keyboard, paged history/retry/dedupe, denial/unsupported states, mutation and
lifecycle revocation, native reconnect navigation and original identity, and opening
unknown work before/after controller recreation. Existing canonical controller,
controls, transcript and bounded-transport tests remain required regressions.

The opt-in `test/integration/hermes_official_canonical.dart`,
`test/integration/hermes_official_runtime.dart` and
`tool/hermes_canonical_probe.py` run installed official authority with isolated
state and explicit non-inferencing execution. Their actual invocation results must
be reported separately from normal fixture tests; merely having the harness is not
a passing backend gate.

**Keep #38/#59 open for the user's deployed server and physical phone.** No user
host, reachable production WSS grant or device was provided. Fresh host-issued
invites still require operator-secured forwarding/bootstrap; Saathi does not mint
one with an API key. Controlled official-runtime success is not production model,
native secure-store, device accessibility or published-release acceptance. Parent
integration owns full-suite/coverage, independent review, CI, PR and merge; no manual
release is implied.
