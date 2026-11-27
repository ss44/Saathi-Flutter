# Full-codebase audit and remediation: issue 68

## Provenance and scope

- Audit date: 2026-11-17 UTC.
- Immutable baseline: `0951a2262a3d4066cc31685a049dde140775182f`.
- Model: **GPT-6 Astra**, exact session model ID **`openai/gpt-6-astra`**, provider **`openai`**. Availability was checked in the model catalog; all five section reviewers and the separate adversarial challenger were explicitly assigned GPT-6 Astra through that provider. No weaker model was substituted. Reasoning defaults were not overridden.
- Scope: all 334 tracked paths, reconciled exactly once in the [coverage manifest](2026-11-17-coverage.md): 302 ordinary text files, 7 generated integration files, 23 binary assets inventoried only, and 2 excluded localhost TLS fixture bodies.
- Method: complete section reads, contiguous chunks for large files, reference/call-site searches, cross-module reconciliation, and an independent challenge of the highest-risk candidates. This is a full tracked-source review with explicit exclusions, not a claim to have executed every path or audited dependency implementations.
- Authorization: #68 originally requested an audit only. During this session the user explicitly expanded scope to fix confirmed defects, update agent guidance, create a PR and squash-merge after review/checks. No release was requested.
- Evidence safety: no production inference, user history, private credentials or signing material was supplied to the model. Public upstream protocol source and GitHub CI metadata were used for corroboration. No production server experiment or paid inference was performed.

**Reading baseline findings:** all line numbers below refer to the immutable
baseline, not a moving branch. Findings describe behavior before remediation.
The disposition section records subsequent changes and remaining acceptance;
do not treat this document as a perpetual claim that every finding remains open.

## Priority summary

P1 means a high-impact recovery/consent defect reachable through ordinary app
behavior. P2 means a bounded correctness, privacy, reliability or provenance
problem, with its preconditions stated. P3 means a smaller usability or retention
defect. These labels are remediation priorities, not CVSS scores or evidence of an
exploited vulnerability.

| ID | Priority | Finding | Classification |
| --- | --- | --- | --- |
| A01 | P1 | Orphaned prepared input makes unrelated chats read-only | Recovery correctness |
| A02 | P1 | Per-chat completion capacity becomes a global sending block | Recovery correctness |
| A03 | P1 | Native approval hides the actual command or lacks a preview | Consent correctness |
| A04 | P2 | Credential update can pair old metadata with a new secret after crash | Authority correctness |
| A05 | P2 | Oversized accepted input wedges native queue / fails direct restore | Input/recovery correctness |
| A06 | P2 | Activity navigation bypasses dispatch revocation | Lifecycle correctness |
| A07 | P2 | Notification navigation transfers an unsent draft's destination | Draft ownership |
| A08 | P2 | Another chat's pending text/waiting state appears in current chat | Display ownership |
| A09 | P2 | Native Stop can release queued followers without Resume | Control correctness |
| A10 | P3 | Settled canonical items retain held-owner references | Memory retention |
| A11 | P2 | Canonical live preview accumulates without an aggregate bound | Resource bound |
| A12 | P2 | Public core provider selection retains foreign conversation history | Public API ownership |
| A13 | P2 | Failed preference writes contaminate reconstructed cached state | Persistence correctness |
| A14 | P2 | Installer package version is not bound to the reviewed offer | Defense in depth |
| A15 | P2 | Release publication trusts metadata rather than resolved tag | Conditional provenance gap |
| A16 | P2 | Multiple desktop writers can overwrite whole-state snapshots | Persistence correctness |
| A17 | P3 | Update page opened during initialization never refreshes | UI lifecycle correctness |
| A18 | P2/P3 | Privacy and exact-byte fixtures do not establish claimed inputs | Test quality |
| A19 | P2 | Current-facing docs contradict implemented behavior | Documentation correctness |

## Findings and smallest improvements

### A01: Isolate orphaned prepared recovery

`lib/ui/chat_controller.dart:2140-2155` removes a chat without reconciling its
prepared journal. `_restorePrepared:378-404` throws for the missing chat/source or
changed authority; `load:1841-1845` then sets global `_loadFailed`. An uncertain
request is no longer `busy`, so the UI allows deletion (`chat_home.dart:659-663`).
The result is read-only state for healthy conversations after restart.

Rejecting replaced authority is correct; global irreversible recovery is not.
Prevent unresolved deletion where practical and quarantine already-orphaned
evidence under its original identity. Never drop uncertain records or resend them
automatically. Regression: two sources, uncertain A, deletion/source replacement,
restart, usable B, no network replay, and explicit recovery/discard for A. Existing
`organization_controller_integration_test.dart:155-190` verifies source rejection
but originally asserts only global read-only, missing unaffected-chat behavior.

### A02: Separate capacity from retryable storage failure

`organization.dart:417-427` rejects a conversation's 513th distinct completion;
seen identities are retained (`430-443`). Controller `_flushOrganization:257-277`
leaves the failed item at the backlog head, and `organizationBlocked:153-157`
blocks every chat. Restart reconstructs it from saved reply markers (`1832-1840`).
Retry cannot change capacity. Deleting the offending transcript and restarting is
a destructive workaround, so "permanently bricked" would overstate the finding.

Use a typed, conversation-scoped capacity outcome while preserving the saved
answer and deduplication evidence. Do not silently evict IDs or merely raise the
limit. Regression: 512 stored identities, a new completed reply, healthy chat B,
retry and restart; no duplicate unread/notification creation. The 1,000-entry
organization limit also needs explicit handling, not a generic disk-error loop.

### A03: Preserve a reviewable native approval action

`GatewayRequest` (`hermes_gateway.dart:62-71`) selects
`question ?? description ?? command`, discarding the command when a description
exists, and invents generic display text when all are absent. The native dialog
(`canonical_controls.dart:109-128`) displays only that string and enables
advertised choices without an actionable-preview requirement.

Keep description and actual command separate, and disable affirmative responses
when the action cannot be reviewed; denial remains possible. Validate both UI and
RPC boundary. Regressions: description plus materially different command, absent/
blank/unreviewable command, denial, stale generation and advertised-choice checks.
The pinned upstream Hermes test at commit
`eaac327fac2c2db0b77ee143989d49b29a6f36cb`,
`tests/gateway/test_authority_approval_projection.py`, supplies both fields and
legitimate `once`, `deny`, `always` choices. **`always` itself is not a bypass**;
do not import the distinct HTTP once-only policy without a product decision.

### A04: Make credential publication crash-consistent

`saathi_store.dart:158-166` overwrites a same-ID secure credential before saving
the new metadata epoch; compensation only handles caught errors. A process death
between stores leaves old metadata with the new credential. Prepared direct input
checks metadata (`chat_controller.dart:397-401`) and later reads that secret
(`1860-1864`), so explicit Resume can dispatch old input under replacement authority.

This is **not** automatic resend; dispatched rows remain uncertain. REST run
recovery separately binds a URL/key digest (`run_client.dart:343-344,414-417`).
Prefer generation-specific secure slots plus atomic metadata-pointer publication,
with legacy persisted-data migration and post-publication cleanup. A durable
transaction marker is an alternative with a more visible recovery state.
Regression: recreate the precise crash snapshot between secret and metadata
writes; old prepared input must never use the replacement credential.

### A05: Align admission and restoration bounds

`submit:529-565` accepts arbitrary nonblank text. `_saveCanonicalQueue:576-609`
sets saving state then invokes synchronous `queueInput` outside `try/finally`;
`canonical_chat.dart:155-166` throws above 262,144 UTF-16 code units. Cancel/reconnect then remain
blocked. Direct admission can also persist text/instructions which its own restore
rejects at `chat_controller.dart:366-367` (262,144 / 16,000 UTF-16 code units).

Validate before mutation, preserve rejected drafts, and cover synchronous calls
with cleanup. Use the same bounds at acceptance/write/read. Regression: exact
boundary and boundary-plus-one for native text/direct text/instructions; no network
effect, no stuck saving flag, subsequent normal send works, all written rows restore.

### A06-A08: Centralize conversation ownership at navigation boundaries

Activity-parent selection assigns `c.current` directly (`chat_home.dart:381-390`)
instead of `select` (`chat_controller.dart:2054-2065`), bypassing preparation
revocation. A delayed secret read can survive activity A-to-B, drawer B-to-A and
dispatch without Resume. Use the controller's real selection transition.

Notification selection (`main.dart:28-35`, `openNotificationConversation:2046-2051`)
does not clear/rebind the composer, unlike drawer/activity selection. A draft
from A remains under B; the next explicit Send uses B. It is not auto-send.
Bind composer transitions to conversation identity, preserving same-chat drafts;
per-chat draft storage is an optional separate improvement, not required here.

`pendingText:839-849` returns global direct pending input without checking
`_dispatchingSession`; `chat_home.dart:559-564,990-1017` also treats global busy as
selected-chat work. Scope visible pending content and waiting state to its owner,
while retaining global busy for concurrency admission.

Regressions must use the actual activity and notification paths, not only `select`:
delayed A-to-B-to-A dispatch stays revoked; A's draft never submits through B;
A's pending message/spinner does not appear inside B; A still saves its own reply.

### A09-A11: Bound native execution lifecycle and retained previews

Native Stop (`canonical_controls.dart:66-70`) calls `control('interrupt')` without
the REST path's follower pause (`chat_controller.dart:962-965`). Cancelled terminal
reconciliation removes the head and schedules followers (`1235-1243`;
`canonical_chat.dart:573-600,625-642`). Pause the captured queue before Stop; keep
the explicit "Interrupt, then queue draft" action distinct. Test cancelled receipt
plus queued B, requiring Resume before B submits.

`_canonicalHeldOwners` receives each queued item (`chat_controller.dart:578`) but
only cancellation removes it (`636`); settled items retain input and owner objects.
Remove entries after definitive ownership transfer, not while still undispatched
and dependent on the original cancellation owner. Test successful transfers and
retained cancellability after failed admission.

`CanonicalChat._event:646-660` repeatedly concatenates preview deltas without an
aggregate limit. Bounded WebSocket messages do not bound a sequence of messages.
Cap retained preview with truthful truncation/resync state, preserving receipt
reconciliation and no-resend guarantees. A `StringBuffer` alone is not a bound.
Test many valid small deltas exceeding the budget, then authoritative completion.

### A12: Prevent implicit core history transfer

`SaathiCore.selectModel:124-130` and implicit selection after `removeProvider:115-122`
retain history; `sendMessage:367-375` sends it through the newly selected provider.
The current app creates a fresh dispatch core and explicitly restores its captured
chat (`chat_controller.dart:2239-2258`), so this is an exported API issue, not an
established ChatHome leak. Clear/rebind history on crossing provider IDs, including
removal; preserve intentional same-provider model behavior. Explicit restore/raw
context remains possible. Test A's private exchange never reaches B after either
selection or removal.

### A13: Compensate false/throwing preference writes

`ReplyNotifications.setEnabled:65-68` retains its old field after failure but leaves
the preference cache mutated; its constructor trusts that cache (`33-35`). The
existing fake explicitly mutates before returning false, but tests only the old
object. `SaathiStore.saveChats:249-251` has the same reconstruction gap.

Restore the prior cached value on failed writes, preserving honest failure when
rollback durability is uncertain. Regression: failed enable and disable, throwing
write, failed chat save/deletion, and reconstruction over the same cached store.
Do not mistake cache compensation for a cross-store atomic transaction.

### A14-A17: Close native/update/provenance gaps

**A14.** `update_installer_io.dart:28-36` passes only a verified path. Android
`MainActivity.kt:44-48,61-82` verifies package, signer and newer versionCode, not
equality to the displayed offer. Pass expected build/version and compare both
before handoff. Test a correctly signed/package-matching newer APK whose metadata
differs from the offer. Release-side verification reduces normal-path likelihood;
this is not an unsigned-code installation bypass. Native installation remains a
separate acceptance requirement.

**A15.** `release_pipeline.py:79-86,196-224` trusts mutable `target_commitish`
without resolving the release tag. A different authorized ref writer can create/
move that tag during builds while artifacts remain pinned to the original SHA.
Subsequent planning/notes trust the tag (`42-44,136-145`). Resolve lightweight and
annotated tags, fail closed on mismatch/API error, bind absent-tag creation, and
check publication readback. Tag protection is also necessary against later
mutations; checking alone cannot make every race impossible. An **executed offline
mock** confirmed baseline publication made only release GET/GET/PATCH/GET calls,
zero tag-resolution calls, while accepting six synthetic assets. No live mismatch
or compromised release is claimed. Regression: valid metadata A, actual tag B,
no promotion; include absent/annotated tags and lookup errors.

**A16.** Linux uses `G_APPLICATION_NON_UNIQUE`
(`linux/runner/my_application.cc:145-147`); Windows starts another engine per launch
(`windows/runner/main.cpp:20-33`). Preferences/history are cached per process and
saved as whole-state replacements (`saathi_store.dart:67-84,206-249`). Two writers
can erase each other's changes. Enforce single-instance activation on these
desktop runners; Linux activation must present the existing window too. Genuine
multi-window support would require a larger transactional store design. Test native
second-launch behavior separately from static runner-contract checks.

**A17.** `UpdateSettingsButton` captures a null scope/controller during package
initialization (`update_host.dart:75-82`); the already-open page does not observe
later initialization (`153-160`). Resolve the live scope in the destination or
observe initialization. Test opening before delayed package info succeeds/fails
and updating that same route, without a new state-management abstraction.

### A18-A19: Make tests and documents prove what they say

`prompt_optimizer_acceptance_test.dart:333-335` restores private history and then
calls `setSystemPrompt`, which clears it. Set the prompt first, restore history,
assert nonempty preconditions and unchanged history after rewriting. Production
`sendRaw` currently excludes it; this finding is missing test strength, not a
proven disclosure.

`agent_run_ledger_safety_test.dart:144-145` claims deliberately noncanonical JSON
but assigns the payload to itself. Seed valid noncanonical persisted bytes and
assert exact retry bytes/key after reconstruction. Do not add mutable production
journal APIs solely for a fixture.

README's completed-response-only and unfinished connection-edit claims conflict
with runtime/connection tests. `UI_DECISIONS:25-26` and
`STABILIZATION_INTEGRATION:57-59` describe superseded integration state;
`PORT_AUDIT:31` gives obsolete Hermes discovery `/v1/models` rather than
`/api/model/options`; `VERIFICATION:33-38` reads like a current verdict.
Correct current entry-point documentation and label historical reports without
rewriting their old evidence. Keep actual device/deployment limitations explicit.

## Independent challenge and reconciliation

A separate context reviewed A01-A04/A15 against source and call chains, not just
the initial summaries. It accepted the recovery isolation, completion-limit,
direct-prepared credential crash, hidden-command and conditional tag findings.
It narrowed the claims as reflected above:

- A02 has destructive recovery by deleting the offending chat and restarting; it is not an irreversible brick.
- A04 requires a process-death window and explicit Resume of a prepared direct input; REST's secret-scope binding is separate.
- Advertised native `always` is legitimate upstream behavior, not an arbitrary/stale-choice bypass.
- Missing endpoint fields in canonical journal keys are **not a demonstrated application defect**. URL/type changes create a new connection ID (`chat_controller.dart:1934-1953`), and fresh invites verify URL/profile/instance. API keys are not native grant authority. No redundant compatibility layer is justified by that rejected hypothesis.
- Missing macOS keychain-access-groups is **not a finding**: the app explicitly uses the legacy standalone Keychain option and tests document that policy.
- An ordinary stale canonical-save-retry reconnect bug was not established; existing unsaved-change gates prevent the simple proposed path.

Section A reconciled UI ownership with B's queue/control contracts and C's
persistence/completion behavior. C and D reconciled Dart installer intent with
native checks and cached storage with desktop process lifetime. E compared actual
integration tests and documentation with those implementation paths. This avoids
treating independently plausible module findings as proven end-to-end defects.

## Maintainability and non-actions

`ChatController` (2,319 baseline lines) and `ChatHome` (1,594) combine substantial
responsibilities. The proven maintenance defect is bypassed selection policy,
not length by itself. Stabilize behavior first; #66 owns later adapter extraction
after #59's deployed-host/device acceptance. Do not make that refactor a
prerequisite for these fixes.

Reference searches corroborated the following, without blanket dead-code claims:

- `ConversationOrganizationList` has only its declaration/state and a test instantiation; the shipped drawer uses `ConversationActionRow` separately. Move essential acceptance assertions to the actual drawer before considering wrapper removal. A concrete external consumer would change that decision.
- `runSnapshots`/`_runUpdates` have no tracked consumers, but form a public surface. Confirm compatibility requirements before deletion.
- Connection whitelists, two optimizer provider allowlists and two Markdown branches are small duplication opportunities, not independently valuable rewrites.
- All direct runtime dependencies have actual call sites: `crypto`, Markdown, secure storage, HTTP, package info, preferences and URL launcher. Test platform-interface/lints dependencies are justified. No dependency removal is supported; transitive sources/advisories were not audited.
- Keep the distinct inference/activity SSE parsers and bounded WebSocket normalizer; their wire/lifecycle contracts and tested SDK workaround are not interchangeable repetition.
- Keep intentional OpenClaw prototypes deferred under #16, installer stubs and generated plugin wiring. Exported documented transport APIs are not dead solely because the current UI has few callers.
- Avoid cosmetic churn, broad fixture frameworks, blanket helper extraction and speculative universal adapters. Do not reinterpret #67/#64/#63/#62/#61 or media #7/#9 as audit defects to implement here.

## Test quality and remaining acceptance

The baseline suite already covers authority revocation after async boundaries,
false-write compensation in several ledgers, uncertain delivery, save-only retries,
canonical completion transactions, bounded TLS/WebSocket framing, safe Markdown,
and 360/390px controls with large text and keyboard insets. Preserve these tests.
Aggregate coverage is not a substitute for the growth/crash/navigation cases above.

Static native source assertions do not prove installer/signature execution or
second-process activation. The macOS example test is empty. Branding tests sample
only a few pixels; screenshot fixtures are not device acceptance. Controlled
official-backend probes with stub execution do not prove paid inference or the
user's deployed host. Actual OS secure-storage durability, Android permissions/
installation, clean-machine desktop launches and assistive technology remain
native/device checks. Long authoritative-history retention deserves a separately
defined mobile budget rather than silently dropping history. Repository release-tag
protection is an operational acceptance gap, not something a local unit test proves.

## Verification evidence

Baseline [Verify Saathi run 44023119185](https://github.com/ss44/Saathi-Flutter/actions/runs/44023119185), bound to the audit SHA:

- Dart formatter: 173 files, 0 changed.
- Fatal-info/fatal-warning analyzer: no issues.
- Flutter suite: 668 tests passed.
- App line coverage: **7,270 / 7,735 = 93.98836%**, above the unchanged 85% floor. Only the two non-executable directive barrels were separately audited by the existing checker.
- Python tooling: 107 tests; branding: 1 test.

Local audit execution independently passed the same 107 tooling and 1 branding
tests. Flutter was initially unavailable locally. For remediation, the exact CI
SDK was then cloned by tag: Flutter **3.47.9**, framework
`c197ca5199e9ee5661e865596c9c07294dfab51c`, Dart **3.13.7**;
`flutter pub get` completed without dependency upgrades. Section audit findings
were initially source-backed with **proposed, unexecuted** Flutter regressions;
subsequent red/green execution must be recorded separately below.

The manifest validator compared its explicit entries with `git ls-tree` at the
baseline: **334 unique paths, no omissions or extras**. Binary/fixture exclusions
are not counted as read source. A code-only `graphify update .` was also run during
remediation, without an LLM call; its generated graph is a local navigation aid,
not evidence for the baseline manifest. It warned that two JSON asset files had
zero extracted nodes. The graph/cache is outside the source patch.

## Remediation disposition

The bounded correctness changes are implemented and locally verified. The table
below separates those changes from deliberately retained limitations. Baseline
findings above remain immutable evidence; the PR records its exact head, CI and
merge outcome rather than implying these local checks certify a published build.

| Findings | Implemented disposition | Principal regression evidence / residual |
| --- | --- | --- |
| A01 | Prevent unresolved deletion; quarantine orphaned/replaced-authority inputs with an additive durable marker; retain explicit discard | `test/ui/audit_recovery_test.dart`, `test/prepared_journal_false_write_test.dart`; two restarts and failed discard retain exact evidence. Malformed storage / failed quarantine persistence still fail closed. |
| A02 | Typed per-chat completion capacity no longer becomes a global backlog barrier | `test/ui/audit_recovery_test.dart`, `test/chat_organization/organization_safety_test.dart`; healthy B sends across restart. A remains explicitly limited; global entry/byte retention policy is deferred, not silently solved by eviction. |
| A03 | Separate action preview; reject unreviewable affirmative approvals at UI and RPC boundaries, retain denial and advertised choices | `test/gateway/canonical_controls_test.dart`, `test/gateway/canonical_chat_test.dart`; conservative credential-like preview filtering can require review at the original host. |
| A04 | New secure slot first, metadata epoch/pointer publication second, old-slot cleanup last; legacy records remain readable | `test/storage/saathi_store_test.dart` and connection/control/activity tests. Process death may leave an unreachable secure slot; no automatic orphan-secret garbage collection or native durability certification. |
| A05-A08 | Shared input bounds and synchronous cleanup; activity selection revokes; drafts/pending indicators stay conversation-owned | `test/ui/audit_recovery_test.dart`, `test/ui/canonical_queue_admission_test.dart`; actual activity and notification navigation. |
| A09-A11 | Ordinary Stop holds followers; settled owner references release; cumulative native preview is bounded with persistent omission feedback | `test/ui/canonical_queue_admission_test.dart`, `test/gateway/canonical_chat_test.dart`, `test/gateway/canonical_controls_test.dart`; authoritative-history budget remains separate. |
| A12 | Crossing provider IDs clears core history, including implicit replacement after removal | `test/core/security_test.dart`; same-provider model switching remains supported, explicit restore remains explicit. |
| A13 | Cache compensation for notification/history writes; reject overlapping notification mutations through permission/write/compensation | `test/notifications/reply_notifications_test.dart`, `test/storage/saathi_store_test.dart`; false/throwing writes and recreated state. |
| A14/A17 | Pass/check exact offered build/version; already-open update page observes initialization | `test/updates/saathi_updates_test.dart`, `test/platform/android_updates_test.dart`, `test/integration/update_host_test.dart`; Android native/device validation remains open. |
| A15/A16 | Resolve actual release tag at publication boundaries; desktop-session single-instance activation | `tool/test_release_pipeline.py`, `tool/test_desktop_single_instance.py`; native/operational limits below remain open. |
| A18/A19 | Correct fixture preconditions/exact bytes; reconcile current docs and label historical evidence | Optimizer/ledger tests, README and affected docs; root and `.agents/` guidance now carry durable invariants and follow-up links. |

Completed focused evidence (not a substitute for final integrated checks):

- A03/A11/A12: initial focused run had 15 passing and 4 failing cases for provider history, preview growth and missing approval preview. Stop-callback ordering and persistent truncation feedback also failed before correction. The completed core/gateway selection passed 146 tests, with scoped analyzer and formatter clean.
- A01/A02/A05-A10: 14 meaningful failures were observed before fixes (11 initial recovery cases, actual activity navigation, and 2 native queue cases). The final UI plus organization/prepared-recovery selection passed 145 tests. A separate integration reviewer reran 96 focused tests after checking the frozen diff and found no remaining actionable controller/UI findings. A failed-discard assertion was corrected to require its action-specific error and retained cache/durable evidence, rather than incorrectly demanding the unrelated chat-history-save flag.
- A04/A13/A14/A17: four initial failures covered notification/cache reconstruction, chat cache loss, delayed update-page initialization and absent expected package metadata. Those became 34 passing tests; crash-snapshot/typed-capacity regressions also went red then green. The expanded support/connection fault matrix passed 88 tests. Android checks here are a mocked Dart bridge and source contract, not device execution.
- Credential-reader integration: the rotated-credential activity case failed with expected one event GET, actual zero. After using the published secure slot, the full activity suite passed 35 tests, covering correct authorization headers and revocation for legacy and rotated credentials.
- A18: adding only the intended fixture preconditions first produced four failures (three empty-history provider cases and one canonical-payload case). After correcting setup, `flutter test --no-pub test/prompt_optimizer_acceptance_test.dart test/agent_run_ledger_safety_test.dart --reporter expanded` passed all 33 tests. These red tests exposed faulty fixtures, not production behavior. Focused analyzer/format checks passed.
- A15/A16: Python release and desktop regression suites passed after meaningful red tests for missing provenance validation and second-instance contracts. A separate implementation reviewer ran `PYTHONPATH=tool python3 -B -m unittest tool/test_release_pipeline.py tool/test_desktop_single_instance.py`: 24 passed, no actionable findings in those five changed implementation/test files.
- Linux native compilation: `flutter build linux --debug --no-pub` succeeded. This is a debug build, not a published artifact or proof of second-launch/focus behavior. Windows compilation/runtime, Android native installation and physical-device checks were not run.
- Native/release review confirmed same-desktop-session single-instance scope. Separate-login shared-profile concurrency and a Windows second launch before the first HWND exists remain limitations; the latter can miss foreground activation but does not create a second writer. Release tag checks are not atomic against another authorized ref writer, so tag protection remains necessary.

The first integrated Flutter run exposed fixtures that still intercepted writes
to the legacy credential key or supplied only an in-memory connection without
persisted metadata. The failure injectors now target the new secure-slot namespace,
and the optimizer fixture persists its configured source before exercising delayed
secret reads. The original authority assertions were retained; the three affected
optimizer/control test files then passed all 39 tests. A failed earlier run is not
counted as a successful full-suite result.

Independent implementation review also found a new overlapping-notification-write
race in cache compensation: an older failed write could roll back a later successful
opt-out. A synchronous busy guard now rejects overlap throughout permission, write
and compensation, releasing in `finally`. Two deterministic interleaving tests
failed before correction; all 12 notification tests passed afterward. Rejected
overlapping calls report failure rather than claiming a successful opt-out.
The original independent reviewer then inspected the correction, reran those 12
tests, and marked the finding addressed with no other actionable findings remaining
in the reviewed support/protocol changes. The final Linux debug build was also
rerun after integration. Manifest reconciliation, 20 local handoff-document links
and `git diff --check` passed.

Local integrated checks on the remediation patch before concurrent upstream integration:

```text
flutter test --coverage --timeout 60s --reporter failures-only
  712 passed
python3 tool/check_coverage.py coverage/lcov.info --minimum 85
  7423 / 7870 = 94.3202033% app Dart line coverage
flutter analyze --fatal-infos --fatal-warnings
  No issues found
dart format --output=none --set-exit-if-changed lib test
  175 files, 0 changed
python3 -m unittest discover -s tool -p 'test_*.py' -v
  117 passed
python3 -m unittest discover -s test/branding -v
  1 passed
```

The original 85% floor and exclusions were not loosened. No real-device,
deployed-host, paid-inference, manual-release or published-binary acceptance is
claimed. Merge is conditional on applicable CI for the exact PR head and completed
independent review, with follow-up issue comments preserving those distinctions.

### Concurrent upstream integration

While preparing the PR, `main` advanced to
`6c7bb79b9073f9cd1f30f0234c9101421022087a` (#69, Send/Enhance actions). It was
merged without conflicts, preserving its new action group and accessible controls.
A separate review of the combined result passed 84 focused tests and found no
actionable integration issue. These new upstream paths are not retroactively part
of the 334-path baseline inventory. The final combined local result is **720
Flutter tests passed**, **7,447 / 7,894 = 94.3374715%** app coverage, clean strict
analysis, **177 formatted files / 0 changed**, and a successful Linux debug build.

One preceding combined full-suite run had **719 passes and one intermittent
failure** in the unchanged `bounded_websocket_test.dart` case "fragmented UTF8,
legal controls, split payload and multiple messages": `Null` was not a subtype
of `Future<bool>` in SDK `_StreamIterator.moveNext`, through
`_BoundedSocket._incoming`, including a late error after test completion. A
separate source/SDK investigation could not establish the root cause: the isolated
case passed once plus 20 repeated runs, and the complete 57-test bounded-transport
suite passed five coverage runs (285 tests). The exact full-suite retry then passed
all 720 tests. No framing/backpressure change or weakened assertion was made on
speculation. **The intermittent observation is not claimed fixed**; preserve it
under #59 for full-parallel-load reproduction, including the original failure
alongside later passing evidence. Applicable PR CI must still pass before merge.

## Follow-up order

Keep these independently reviewable, with no speculative refactor folded into
the correctness patch:

| Order | Follow-up | Type and acceptance | Existing context |
| --- | --- | --- | --- |
| 1 | Validate corrected Hermes flows on the user's host/device | Acceptance: real existing session, interruption, approval, lost reply, restart, navigation, no duplicate submission | #59, #37, #38 |
| 1 | Reproduce intermittent bounded-stream iterator failure | Diagnostic: capture the full-parallel coverage shutdown path; isolated repeated passes do not explain the observed SDK null-future failure | #59; concurrent integration evidence above |
| 2 | Define total organization/history capacity recovery | Behavior/persistence: whole-ledger entry/byte limits and long authoritative transcripts need an explicit retention/recovery contract, without losing dedupe or private history | #28, #59 |
| 3 | Verify native credential/update/desktop lifecycle | Native acceptance: secure-storage crash recovery, offer/version/signer rejection, installer permissions, two-launch behavior and focus on Windows/Linux | #59 and this report's A04/A14/A16 |
| 4 | Configure/verify release-tag immutability | Operational safeguard: protect publication source against later authorized ref movement; no release dispatch implied | A15 |
| 5 | Consolidate only demonstrated maintenance duplication | Behavior-preserving: actual-drawer coverage before removing unused organization wrapper; confirm public consumers before pruning streams; whitelist/allowlist consolidation only with relevant schema edits | #28, #59 |
| 6 | Extract proven adapter boundaries | Architecture only after Hermes acceptance; preserve direct-model separation and contract regressions | #66; #16 remains deferred |

Recommended order remains: recovery/authority/consent fixes first; bounded
navigation/input/stream lifecycle fixes next; native/update/provenance safeguards;
test/documentation corrections. Behavior-preserving cleanup is separate from
correctness fixes. Riskier schema/authority changes require crash and legacy-data
regressions; native changes retain their unexecuted device checks. Existing #59,
#28, #34 and #38 retain their real-use acceptance; #66 and #16 remain sequenced/
deferred, not silently completed by this work.

### Later change to photo submission

The Hermes HTTP Runs photo flow extends the A05–A08 checks. The composer bounds selected photos before queueing and revokes a pending picker on conversation selection or connection mutation. The secure Runs journal validates structured inputs at save and restore. Tests exercise the actual composer at 360px with 2× text and a keyboard inset, exact request bytes and key before POST, and restart with a lost receipt followed by read-only history recovery. The matcher rejects missing or ambiguous photo evidence. Platform picker behavior, native secure-storage capacity, and the user's deployed Hermes API remain separate acceptance checks. See [photo composer tests](../../test/ui/chat_photo_composer_test.dart) and [history matching tests](../../test/agent_runs/run_history_sync_test.dart).

The Flutter suite recorded 1,349 passes and 12 failures. All 12 failures reproduced on the starting revision for this change. Dart line coverage was 10,188 / 10,710 (95.13%), and strict analysis passed on the CI-pinned SDK. The Android debug APK built successfully.
