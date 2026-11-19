# Hermes-first delivery acceptance and review handoff

## Gateway-first follow-up, 2026-11-19

New Hermes setup now selects the canonical desktop gateway rather than the
ordinary inference API. Persisted REST connections remain labeled legacy and
retain their original conversation and recovery ownership. Native creation uses
the advertised `session.create` contract with host defaults; it does not send a
prompt or imported transcript. Its secure intent journal preserves unknown
creation across restart and never automatically retries it with a new grant.
Existing native conversations have an explicit original-profile reconnect.

Controlled regression coverage was added for capability gating, journal-before-
create ordering, unconfirmed creation, source revocation, duplicate-address
connection identity, delayed attachment after navigation, profile mismatch,
stale session-list invalidation and creation-recovery isolation. Mobile route
tests exercise native creation at 360/390 px, 2x text and keyboard insets. These
are fixture checks, not new live-server/device evidence.

Local verification of this follow-up on Flutter 3.47.9 / Dart 3.13.7:

- All 997 Flutter tests passed in a clean full-suite rerun.
- Application line coverage: 8377/8817, 95.01%, above the unchanged 85% floor.
- Strict analyzer, repository Dart formatting, and `git diff --check` passed.
- 117 Python tooling tests and the branding test passed.
- `flutter build linux --release --no-pub` built
  `build/linux/x64/release/bundle/saathi`. This is a local binary, not a published
  release, deployed-host result, or Android device acceptance.

Upstream creation/bootstrap source was inspected at official Hermes commit
`52811481bc07b18b073790cd2a168a832c92acd7`. Stock same-device WS loopback invites
are accepted; remote addresses still require WSS and explicitly secured
forwarding compatible with the native host's loopback authentication gate.
REST tokens are never translated into gateway grants. Native OAuth sign-in,
automatic grant renewal, remote deployment/device acceptance, and verified
model/tool configuration controls remain open. #59 acceptance still precedes
adapter extraction under #66. Historical evidence below has not been rewritten
as verification of this follow-up.

## Verdict and scope

**Hermes source is ready for exact-diff independent review, not merged, built,
shipped, device-approved or independently approved.** The parent owns PR60, final
review, CI, merge and the single conditionally authorized beta dispatch.

The user's latest scope is **Hermes first**. Issue #16/new OpenClaw pairing and
native integration are explicitly deferred until Hermes is accepted. None of the
isolated OpenClaw38/40 slices or their follow-up journal work was integrated.
New direct-provider vision, image generation, Android SAF/share intake/export and
picker wiring are excluded, not left as reachable disabled-by-assumption paths.
Existing plain-text providers, optimizer, organization/personas, privacy, storage,
queue and usage regressions remain in the normal suite.

Before extraction, the complete combined WIP was preserved outside this repository:

- `/opt/data/cache/scratch/saathi-hermes-pre-scope-wip/manifest.json`
- `FULLBASE.patch`, `additional-over108.patch`, `source.tar` in that directory.
- Preserved exact tree: `793bf871728c841b59aaa41668c94e64afc98a65`.
- `excluded-media-paths.json` records the isolated new media files and media-only
  platform paths restored to the verified base. Media-only tests moved with their
  feature, not into skips. Non-media journal, visibility and new-chat regression
  cases from the mixed probe were retained.

The delivery was extracted semantically from the corrected108 union and new
canonical fixes. Shared controllers were **not replaced by old39 controllers**.
The six independently frozen WebSocket guard files remain byte-identical.

## Acceptance table

“Official” below means installed, read-only `/opt/hermes` authority, runtime API,
WSS authentication, transcript store and receipt machinery, with only agent
execution replaced by the explicit non-inferencing stub. It does not mean a paid
provider turn, the real Desktop executable, Android device or deployed user host.
“Fixture” means real local WS/WSS and actual controller/ChatHome where stated.

| Requirement | Result and exact evidence |
| --- | --- |
| Existing external session → attach → new input → same-session result | **Official + actual ChatHome verified.** `test/integration/hermes_official_canonical.dart` drives drawer/import/attach/normal composer, then reads authoritative original-session history. Only new text/input identity is uploaded. |
| Stuck thinking / real streamed answer / authoritative completion | **Official + actual ChatHome verified.** Visible streaming body, pending state, one final answer, external-client completion resync, no duplicate final body. Admission is not completion. |
| Guide / Correct / Queue / hard interrupt | **Actual ChatHome fixture verified at 360/390 × 800, 2× text, 260px keyboard.** `test/gateway/canonical_combined_home_test.dart` exercises Guide and Correct, then interrupt + durable next-turn queue. Stop ACK remains pending; no second `prompt.submit`. Official actual-UI Guide also passes. Native control acceptance is not a claim that a real LLM followed its text. |
| Approvals and clarification questions | **Actual ChatHome fixture verified at both sizes.** Explicit advertised approval choice and typed clarification answer send `approval.respond` / `clarify.respond`; neither is inference. Dialog controls remain reachable with long draft and keyboard. Component tests cover stale/refused decisions. No fixture decision is represented as an official real-tool approval. |
| Admission / terminal / saved-history FIFO barrier | **Combined controller verified.** Followers remain held through admission, active work and authoritative save. Native FIFO is source/profile/session-scoped secure storage, separate from the per-operation journal. Head identity is stable through queue dispatch. |
| Durable followers / explicit Resume / storage-only retry | **Combined controller recreation and failure paths verified.** `canonical_combined_controller_test.dart` restores second/third accepted inputs in order without replaying admitted first input, requires Resume, preserves mounted followers across fresh reconnect, retries failed FIFO storage without RPC, retains original journal on failed cancellation, and removes a completed durable head before deleting its no-replay journal. |
| Lost ACK with actual Dart-owner process death | **Official verified.** `tool/hermes_canonical_restart_probe.py` starts distinct Flutter child processes using a real persisted test-secret store. A controlled TLS forwarding peer drops only the real admission response. Recovery uses exact pending input ID + receipt, then persists authoritative history before clearing the journal. Exactly one actual submit. |
| Lost ACK with official backend process death | **Official verified.** The same probe SIGKILLs the controlled backend and restarts the official authority/store over the same database. Exact persisted submission metadata is present. A receipt without terminal proof remains **unknown**, journal stays durable, followers remain held and another submit is forbidden. Exactly one actual submit. No fabricated terminal answer. |
| A→B→A / original A completion while B selected | **Official actual UI and combined-controller verified.** A's completion is saved only into A, B remains selected/unchanged, old input/control authority never revives. |
| Background → foreground | **Combined controller + existing actual-ChatHome lifecycle regressions verified.** Suspension disconnects old native authority. Resume alone cannot restore a spent grant; a fresh host invitation is required. Held queue retains explicit Resume. |
| Credential mutation at START, including delayed/failed write | **Combined controller over actual fixture WSS verified.** Mutation revokes native authority synchronously before the secure-write gate; failure/rollback cannot revive it. Existing critical Runs/control leases and delayed credential regressions remain in the full suite. |
| Delayed journal write / attachment change | **Independent repro RED→GREEN on this union.** Both first and second secure-write checkpoints are tested. Attachment spends the send epoch; immutable journal/session/profile capture and the client's explicit expected target prevent A-private-text submission into B or contamination of B's journal. |
| Same endpoint/session ID under profiles P and Q | **Independent repro RED→GREEN.** Immutable whitelisted `canonicalProfileId` participates in local identity lookup and persistence. Q gets a distinct local conversation; P history is retained. Old unscoped local rows are not silently upgraded or overwritten and remain read-only. Recovery validates exact journal session/profile. |
| New chat / clear / direct selection bypass | **Independent repro + follow-up RED→GREEN.** Corrected108 successful new-chat selection policy is retained. Failed new-chat/clear persistence and direct selected-owner A→B→A cannot revive old approval/control authority. Central selection setter fences native authority too. |
| Paged history / compression / reader anchoring | **Adapter real-WS cursor paging/reset + actual ChatHome verified.** Oldest-order pages use opaque cursors, dedupe durable rows and stop on an empty page. A surviving visible reader row retains its exact screen position after prefix compression at both phone sizes. Wheel and trackpad keep older reading position; undisturbed live edge still follows actual deltas. No claim to preserve content the server has deleted or to provide a separate latest-order history browser. |
| Pending approval + long draft + narrow composer | **Joint actual ChatHome fixture verified.** Native status is in bounded scrolling feedback, not an unbounded fixed-height block. Existing approval + child activity + optimizer joint ChatHome regression also passes at both widths. |
| Personas / organization / unread / usage | **Combined verified.** Existing native conversations use server-owned persona policy; no server system-prompt mutation is invented. New native durable assistant rows receive stable completion identities; imported history does not become a new unread answer. A completion while B is selected is tracked in A's organization metadata. Missing usage is absent, not fabricated zero/price/context percentage. |
| Original critical four and corrected108 non-media fixes | **Retained and normal-suite verified.** Control/key-mutation/selection leases, queue/new-session pause policy, wheel/live-edge fixes, real MethodChannel false-write cache compensation, immutable accepted persona snapshots, organization/unread/usage and storage-only recovery remain. Media-only ownership paths are preserved in WIP, outside this user-selected delivery. |
| Bounded adapter fragment transport | **Verified through actual canonical client and frozen helper tests.** Legal fragmented RPC survives nonempty ping, oversized unfinished continuation chain is rejected before FIN; all six approved helper bytes are unchanged. |
| One-use / expiry / trusted host / secured loopback forwarding | **Official controlled-WSS proof + client tests.** Tickets are deleted before dialing, issuer expiry remains 30 seconds, negotiated profile/instance must match, redirects and insecure imports are refused. Forwarding is explicit operator infrastructure, not a broker or an API-key-to-ticket invention. |
| Public host / native OS secure store / physical Android | **Deployment/device acceptance deferred with concrete prerequisite.** The stock host export is loopback `ws://`; importing it on mobile is intentionally rejected. Operator must deploy a trusted WSS path preserving the official loopback Host/Origin/native-peer gate and export that exact reachable URL. No user deployment or production grant was provided, and this worker is not authorized to build/dispatch. OS storage and device gestures require the later parent-owned build/device gate. |
| Independent final review / CI / merge / beta | **Pending parent gates, not worker approval.** This document and passing totals do not waive those gates. |

## Fresh gates and commands

Normal full suite on the extracted Hermes source: **655 passed**, normal assets,
concurrency 2, per-test 60-second timeout. Real app Dart coverage is
**7162/7624 = 93.9401888772%**, unchanged minimum 85%. Python 3.13 tooling ran
**107 tests**, plus **1 branding test**, with `Pillow==13.0.0` explicitly installed
in a scratch venv. Fatal analyzer/format results and hashes are bound to the final
snapshot in the external manifest/evidence bundle; do not substitute a previous
combined or canonical-only total.

```sh
flutter test --no-pub --coverage --concurrency 2 --timeout 60s
python3 tool/check_coverage.py coverage/lcov.info --minimum 85
flutter analyze --no-pub --fatal-infos --fatal-warnings
dart format --output=none --set-exit-if-changed lib test
/opt/hermes/.venv/bin/python tool/hermes_canonical_probe.py
flutter test --no-pub test/integration/hermes_official_canonical.dart --timeout 240s
/opt/hermes/.venv/bin/python -u tool/hermes_canonical_restart_probe.py
python3.13 -m unittest discover -s tool -p 'test_*.py' -v
python3.13 -m unittest discover -s test/branding -v
```

Fresh external logs use `/opt/data/cache/scratch/canonical-hermes-` prefixes:
`full-suite-final.log`, `coverage-final.log`, `analyze-final.log`,
`format-final.log`, `security-final.log`, `final-matrix.log`,
`official-ui-final.log`, `official-restarts-final.log`, `official-probe-final.log`,
`tooling-final.log`, `branding-final.log`. The per-file bundle manifest records
actual SHA-256 values, gate commands/results and source trees.

## Meaningful REDs and harness corrections retained

- Independent session-race and profile-alias REDs: `canonical-combined-independent-security-red.log`.
- Failed new-chat / failed clear / direct-setter selection REDs:
  `canonical-combined-failed-new-session-red.log`, `canonical-combined-clear-red.log`,
  `canonical-hermes-selection-setter-red.log`.
- Original source completion lacked organization state/stable native reply IDs:
  `canonical-combined-organization-red.log`, `canonical-combined-organization-marker-red.log`.
- FIFO followers disappeared on recreation and mounted reconnect lacked Resume:
  `canonical-combined-durable-fifo-red.log`, `canonical-combined-mounted-fifo-red.log`.
- Compression lost the reader and fixed native status overflowed the narrow composer:
  `canonical-combined-compression-red.log`, `canonical-combined-home-focused.log`.
- Official backend restart exposed an unknown receipt that needed truthful landed/
  unproven feedback: `canonical-combined-backend-restart.log`.
- Scope RED proved the old image action was still reachable: `canonical-hermes-scope-red.log`.

Official widget retry initially stalled at the secure FIFO/history save boundary
because a real-only `runAsync` wait stranded widget-clock continuations. Safe
checkpoints isolated the boundary. The probe now drives both real I/O and widget
frames while the same storage-only future completes, still requiring unchanged
attachment identity and no resubmission. The restart fixture also hashes secret
identifiers to filenames; raw base64 of a long source/profile tuple exceeded the
filesystem component limit. Neither correction alters production transport,
backend source, authentication, stored metadata or recovery assertions.

No commit, push, GitHub write, paid call, installed-backend patch, signing change,
merge or build dispatch was performed.
