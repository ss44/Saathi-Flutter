# Pending reply presentation (#37 refinement)

This is the pending-message refinement discussed on issue #37, not completion of
its wider native-client checklist.

## Evidence and root cause

The Runs path is `ChatController._dispatch` → `_sendRun` → `RunClient.submit`
(POST admission) → `RunClient.status` (authoritative GET) → `_reconcile` (durable
answer). A successful admission followed by a failed first GET formerly escaped
into the broad dispatch catch, immediately showing “Native outcome unconfirmed”.
The catch also bypassed `_schedulePoll`, so the already-admitted original work
could remain stranded until a manual action. The controlled localhost regression
reproduces this with HTTP 202 followed by HTTP 503 and recovers a completed answer
using only the original run's GET. It does not establish why any deployed server
lost a particular acknowledgement.

The UI separately replaced playful thinking with a static native waiting label
and displayed the raw `Run: started` status. This was presentation policy, not
proof that the server had stopped working.

Canonical Gateway admission has a different path: `CanonicalChat.send` persists
the original input identity before `prompt.submit`. A lost reply used to expose
uncertainty immediately, without trying the existing read-only reconciliation.
Recovery now uses the original session/profile pending table and exact `input_id`
then `prompt.receipt`; matching text is never ownership or terminal proof.

## Queue ownership: server capability versus this client

The recovered refinement originally consulted official API-server documentation
on November 17, 2026. The installed primary source was inspected again during
recovery of this delta; admission can be server-durable:
`gateway/session_controls.py:submission` constructs `Submission(..., 'queue')`
for canonical `prompt.submit`; HTTP Runs has durable admission/idempotency and a
separate server-owned run ID. The current HTTP route inventory is in
`gateway/platforms/api_server_runs.py:_http_routes`. Neither is a reason to call
Saathi's not-yet-dispatched outbox server-owned.

At the current recovery base (`11692bcdff6fef5c0291b63ed0775758633afbad`),
Saathi `submit` puts followers in `_outbox`;
`CanonicalChat.queueInput` writes `gateway.fifo.v1...` to the **device SecretStore**,
not a native enqueue RPC. Runs holds followers locally until its one active
`RunOperation` is settled. Only after actual admission does the server own that
particular input. The device retains its receipt/journal for reconciliation.

Server-owned follower handoff is a real available server capability, not an
invented missing endpoint. The remaining client blocker is multi-admission
ownership: one `_journal` / `client.run` per canonical session and one
`runs[localChatId]` slot cannot safely reconcile, cancel, restore, stream and
persist several admitted inputs independently. Calling `prompt.submit` again
without that work would overwrite active receipt/control identity and risk losing
uncertain outcomes. This refinement does **not** implement that larger handoff.
Native unsent labels must explicitly say they are on this device, not imply a
server queue. Phone-independent native follow-ups remain unfinished; direct-model
FIFO remains honestly local.

## Behavior and limits

- Playful thinking is decorative waiting copy, separate from truthful state.
  It appears immediately while sending and remains during admitted queued/running
  work and bounded reconnect checks. Confirmed failure, unknown/exhausted recovery,
  user decisions and completion do not keep an endless working animation.
  Successful native Guide/redirect acknowledgements and preview-limit notices
  remain visible feedback without ending thinking for that original queued/running
  input. Receipt state, decision state and bounded observation recovery—not the
  mere presence of feedback text—own the loader lifetime.
- Runs uses the existing status scheduler. Consecutive failed reads back off
  through 2, 4 and 8 seconds, then stop automatic recovery and retain a manual
  Check status action. Successful reads reset the recovery budget; valid ongoing
  work is not failed by a fixed total execution deadline. An HTTP 200 alone is
  not a valid observation: omitted, empty, non-string and unrecognized lifecycle
  statuses are rejected before replacing the last snapshot or secure journal.
  They consume the same bounded failed-read budget, preserving exact operation,
  session and history identity. Explicit `unknown` is a supported no-replay state,
  not a malformed observation. `started` remains the supported running alias.
  A genuine background-to-foreground return starts another bounded read-only
  recovery budget for a known reply ID. A manual Check status that observes valid
  ongoing work also restarts the existing automatic poll owner; it must not leave
  an animated running snapshot without further checks. Neither path replays a
  lost admission.
- Canonical lost admission performs at most three read-only reconciliation
  attempts with 250, 500 and 1000 ms backoff. Transport request deadlines still
  bound each read. Source/session/profile/lifecycle revocation stops recovery.
  A disconnected one-use-grant connection needs a fresh host invitation; the app
  does not invent credentials or silently redial consumed authority.
- The installed official HTTP Runs routes expose status by `run_id`, not a
  read-only idempotency-key lookup. When an admission reply is lost before the
  `run_id` is known (`attempted == true`, `runId == null`), Saathi performs a
  bounded automatic and manual read-only chat refresh (`GET /api/sessions/{session_id}/messages`)
  bound to the original connection authority rather than stranding the user on
  an unactionable dead-end notice. After verifying prefix alignment against
  local history, it string-matches the submitted input after existing messages
  to recover a missing `run_id` (transitioning to live `GET /v1/runs/{run_id}`
  status checks) or settle a completed assistant reply. Diverged or foreign
  session history fails closed. Refresh never POSTs an uncertain prompt again,
  even with the original idempotency key; a proven never-dispatched prepared
  operation remains explicitly dispatchable via Reconnect. Canonical exact-input
  receipts remain separate.
- On desktop, public Runs `tool.started`/`tool.completed`/`tool.failed` labels appear
  below thinking. Only bounded tool identifiers are rendered, not arguments,
  result previews, raw errors, reasoning or arbitrary model claims. The current
  canonical event adapter has no verified public tool/model lifecycle projection;
  it shows sending/queued/working/reconnecting evidence, not fabricated telemetry.
- Existing answer streaming, final-result deduplication, durable save and original
  source ownership remain authoritative. Receipt recovery alone does not release
  followers before the recovered snapshot has been saved.

## Android HTTP Hermes: pending bubble and foreground status sync

For HTTP Hermes connections on Android, a message uses the durable Runs admission
and original run ID rather than a generation-long completion request or activity
SSE. Servers without that verified capability get an actionable limitation before
inference; they are not silently downgraded to a fragile compatibility request.

- The assistant waiting bubble follows the pinned `ss44/sathi.ai` plugin's visual
  pattern: immediate playful text, italic
  half-opacity primary text, a primary spinner and local elapsed seconds. It has
  no extra heading or label. Saathi shuffles plugin jokes and 200 new lines,
  leaving out originals that read like actual status or errors. The copy rotates
  every ten seconds while actively waiting in the foreground on all platforms.
  Reduced-motion and accessible navigation keep the phrase static. The elapsed
  clock measures this mounted waiting view, not server execution time.
- Ordinary sending/queued/running labels do not add another block beneath the
  Android bubble. Real recovery, decisions, failures and controls remain visible.
  The Android status-only path does not show the Agent activity button; it has
  no activity stream to fill the panel. Streamed desktop activity, canonical
  Gateway reply streaming, and the separate Stop and decision controls are
  unchanged.
  The final authoritative answer removes the waiting bubble; HTTP event-fed
  partial answers are ignored. Desktop streaming behavior is unchanged.
- Backgrounding suspends observation. Foreground return or controller recreation
  restores the original durable operation and uses bounded status GETs to sync
  its answer. Repeated reads/reloads must not add another inference POST or
  another completion identity. A broken status connection is not proof the
  server failed, and a late response cannot revive revoked foreground authority.
- This is intentionally **not** a copy of the desktop plugin's transport. At
  reference commit `83e73925288b241c692ccdf86b373b11ff9e6cda`, its Hermes
  provider holds an ordinary XHR until HTTP 200 and restores only local history;
  it does not provide detached admission or durable pending sync. Its reply
  typewriter is local animation, not evidence of network token streaming.
- Native `hermesGateway` WSS attachment is a distinct contract and is unchanged.
  No HTTP substitute for its trusted invitation, receipt or session-resume RPCs
  is invented. An HTTP admission ACK lost before its run ID is known remains
  explicitly uncertain: no verified read-only key lookup exists, so it is never
  replayed to manufacture recovery.

Controlled tests cover advertised-events/no-SSE, partial-event rejection,
unsupported servers, warm/cold recovery, failed status GETs, exhausted budgets,
source replacement and exactly-once answer reconciliation. Stream-specific
compatibility tests retain their original assertions on explicit desktop
variants. These checks do not establish Android process-kill, native secure-store
or deployed-server acceptance.

## Recovered delta and additional regressions

The prior uncommitted refinement was three-way applied, not copied over current
source. Current preview bounds, journal ownership, queue cancellation, approval
validation and the adaptive desktop workspace remain intact.

- A previous completed receipt must not suppress thinking for the next input.
  Canonical pending state is bound to its exact input ID; HTTP preparation has
  its own dispatch identity before admission. Terminal answers still stop the
  loader while their storage is pending.
- Authoritative completion retires an uncertainty-only queue barrier. A deliberate
  Pause/Stop, conversation-selection boundary, failed/cancelled outcome or durable
  storage blocker remains distinct. A late exact running canonical receipt clears
  stale recovery copy without releasing its pending journal.
- Ordinary foreground return automatically continues proven-unsent input when
  its exact captured source is still valid. The old dispatch permission remains
  revoked: the queue restores the same accepted item, creates a **new** permission,
  rereads credentials and revalidates source/lifecycle before HTTP. This is not
  revival of a stale callback, uncertain replay or permission to allocate a second
  native operation. Deliberate Pause/Stop and invalidated source ownership still
  block continuation. Already-admitted native work resumes read-only observation.
  A durable never-attempted Runs journal remains under its existing explicit
  original-operation recovery path, retaining the same key and payload rather
  than becoming another queued item. This refinement does not broaden that path.
- Public tool identifiers survive activity projection; private argument, preview
  and raw error payloads do not. No hidden reasoning or invented model progress
  is displayed.

This slice does not implement multi-admission server handoff or reusable native
login/grant renewal. A canonical socket that has disconnected or been suspended
still requires a fresh trusted host invite; background return must not reuse its
one-use grant. The deployed host must expose the original-session receipt and
history contracts through reachable trusted WSS. Android lifecycle/network and
OS secure-storage crash durability need actual device evidence. These are open
acceptance requirements, not properties established by controlled fixtures.

Default tests use controlled HTTP/WebSocket peers and mounted Flutter widgets.
They are not Android-device, production-server or official-runtime acceptance.
No binary build or release is authorized by this change.
