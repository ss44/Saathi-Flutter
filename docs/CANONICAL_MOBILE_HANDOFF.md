# Canonical Hermes mobile connection — historical component delta

> This component handoff is provenance, not the current acceptance verdict.
> [HERMES_DELIVERY_ACCEPTANCE.md](HERMES_DELIVERY_ACCEPTANCE.md) supersedes its
> old39 ownership instructions, unfinished rows and historical gate totals for
> the corrected Hermes-only integration. Preserve this history; do not treat its
> old partial snapshot as the current source.

## Outcome and ownership

This is a **working bounded canonical connection/attachment slice**, not completion
of every #37/#38 acceptance criterion. It is additional unstaged work on
`integrate/hermes` in `/opt/data/cache/scratch/saathi-integrate-hermes` only.

The original 39-file staged seed is unchanged. SHA-256 of
`git diff --cached --binary` remains:

```
21b0eec3b013574ac5ea812ef962c68be3f086ac284f3a67a910aaac917f78a8
```

Parent integration must combine the **unstaged delta plus untracked files**, not
replace shared controller/home/connections files wholesale. The parent's critical
review fixes are separate; none were copied from its changing integration tree.
No commit, push, PR, release, production key, paid inference, private-user-file
read or packaged `/opt/hermes` write is part of this delta.

## User-visible path

1. Open the actual ChatHome drawer → **Hermes Desktop / CLI**.
2. Enter an explicitly trusted `wss://…/api/ws` address, and import a fresh
   host-issued `hermes gateway attach --json`-shaped invitation. The initial
   address is empty. **Trust this host and connect** is explicit consent.
3. Read both official `session.list` scopes, deduplicated by native session ID.
   `stored` alone excludes live canonical sessions. Each scope is bounded to 200;
   the result is not represented as complete inventory or fabricated pagination.
4. Select the original Desktop/CLI session. Native `session.resume` resolves its
   identity; the normal ChatController selection path pauses the previous FIFO.
5. Use the existing ChatHome composer and FIFO. Only `{session_id,text,input_id}`
   is submitted through the existing WebSocket adapter, never prior transcript,
   local model settings, system instructions or HTTP Runs.
6. Actual `message.delta` reaches the existing transcript. Completion triggers a
   read-only receipt/snapshot reconciliation. The original native history is
   persisted before the local operation is released. Other-client completions
   resync the same session, rather than cloning it into API chat.
7. Background and source mutation revoke the transport. Leaving the selected native
   session permanently revokes input/control authority but retains source-bound
   read-only observation long enough to reconcile its completion into the original
   conversation, even while B is selected. A→B→A cannot revive input. Reconnecting
   for input requires another host-issued one-use invitation; connection Edit opens
   the import screen. Native hosts are excluded from the direct-model picker.

`CanonicalChat` is a small native lifecycle/journal adapter, not another Runs API
or replacement inference scheduler. It uses the existing `HermesGatewayClient`,
`ChatController` FIFO and transcript presentation. Its per-input journal lives in
`SecretStore` (OS secure storage in production), under source/session-scoped keys.
A known receipt is reconciled by `prompt.receipt`, not another `prompt.submit`.

## Verified actual invitation and host prerequisites

Primary references inspected:

- Official documentation, fetched live:
  `https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-internals`
- Installed read-only `hermes_cli/gateway_runtime_cli.py::cmd_gateway_attach`:
  the actual JSON adds `url`, `protocol`, `protocols`, `ticket` to the discovery
  verdict and `endpoint` descriptor. There is **no invented mobile login broker**
  or API-key-to-ticket conversion here.
- `hermes_cli/gateway_client.py::gateway_ws_target`: URL is the owner's
  `api_origin` converted to WS/WSS plus `/api/ws`; protocols are
  `hermes-gateway-v1` and `hermes-gateway-ticket.<ticket>`.
- `gateway/runtime_bootstrap.py::TicketStore`: `token_urlsafe(32)`, 30-second
  mint-time lifetime, redeemed once, bound to instance/profile/purpose/subject.
- `gateway/run_api.py::GatewayRuntimeAPI`: native tickets are accepted only from
  a loopback peer, without an Origin header, after host/origin checks. A remote
  peer follows the separate Webapp credential gate, **not** native-ticket auth.

Required host deployment is therefore concrete: provide a deliberately secured
TLS forwarding/tunnelling path that reaches the correct owner's loopback
`/api/ws`, preserves the verified native peer/Host/Origin boundary, and export the
invitation with that exact reachable WSS URL on the trusted host. A plain reverse
proxy configured to forward a remote client identity can deliberately hit the
remote gate and is not automatically sufficient. Do not expose the Unix control
socket, turn off TLS, disable origin/host validation, or treat an API-server key
as a native ticket.

The stock host command normally emits a loopback `ws://…` URL. Saathi intentionally
refuses importing that raw URL for mobile. **The app never rewrites its URL.**
After the operator has actually deployed and verified the forwarding path, an
explicit host-side export can keep the official ticket/protocol/profile fields
and replace only `url` with the operator's established public WSS address:

```sh
# Run on the trusted host, only AFTER establishing the secured forwarding path.
# Keep this credential out of shell logs/files/recordings; redeem within 30s.
hermes gateway attach --json | python3 -c '
import json, sys
from urllib.parse import urlsplit
public = sys.argv[1]
u = urlsplit(public)
assert u.scheme == "wss" and u.hostname and u.path == "/api/ws"
assert not u.username and not u.password and not u.query and not u.fragment
v = json.load(sys.stdin)
assert v["state"] == "ready" and v["protocol"] == "hermes-gateway-v1"
v["url"] = public
print(json.dumps(v))
' 'wss://YOUR-EXPLICITLY-DEPLOYED-HOST/api/ws'
```

This example is an operator-side forwarding export, not an official public grant
endpoint or a deployment Saathi secretly provisions. No user deployment was
changed. The controlled probe instead supplies an explicitly test-trusted local
TLS listener over the official native gate.

`HostInviteVault` verifies the exact typed source, exact protocol/ticket agreement,
profile and instance fields, rejects query credentials and insecure/arbitrary
redirect targets, and stores the whole credential only in secure storage. It
**deletes before dialing**, including failed dials. The local 30-second import
maximum does not extend the host's mint-time expiry; the official server remains
its authority. `runtime.describe` must match the invite's profile and instance.
There is no bad-certificate callback or trust-all mode. Test CA installation is
confined to the test process's `SecurityContext`.

## Executed evidence

Commands, from this worktree:

```sh
/opt/data/tools/flutter/bin/flutter test --no-pub test/gateway/
/opt/hermes/.venv/bin/python tool/hermes_canonical_probe.py
/opt/data/tools/flutter/bin/flutter test --no-pub \
  test/integration/hermes_official_canonical.dart --timeout 240s
/opt/data/tools/flutter/bin/flutter analyze --no-pub --fatal-infos --fatal-warnings
/opt/data/tools/flutter/bin/flutter test --no-pub --coverage --timeout 60s
python3 tool/check_coverage.py coverage/lcov.info --minimum 85
git diff --check
git diff --cached --binary | sha256sum
```

The official probe actually imports `GatewayRunner`, canonical authority,
`AuthorityConnection`, original session creation/resume/admission/receipt/history,
`GatewayRuntimeAPI`, original WS transport and `TicketStore` from `/opt/hermes`.
It clears the subprocess environment and uses a fresh scratch HERMES_HOME. A
separate official Desktop-source (`source: gui`) AuthorityConnection creates the
session. **Only execution at `runner._handle_message` is replaced by the explicit
non-inferencing StubAgent.** This is not a real Desktop executable, provider,
TurnRunner/LLM or Android-device test, and is not described as one.

The host issues the real ticket; OpenSSL creates a localhost certificate; the
client verifies normal TLS against that test certificate. Ticket bytes are
written owner-only in scratch and are never logged. The UI test drives the real
drawer/import/attach/composer path, holds the stub at a checkpoint, requires
visible streamed text while pending, retains a draft, releases the checkpoint,
requires one same-session authoritative answer, then observes another official
client's turn and resyncs without duplication. Selection A→B→A revocation is
asserted. The independent Python probe also requires spent-ticket rejection,
expired-ticket rejection by the actual issuer, and fresh-ticket reconnect to the
same profile. The expiry probe asks the controlled issuer to mint an already
expired ticket; it does not relax expiry in the client or production code.

The ordinary real-WS tests cover source mismatch/expiry, negotiated identity,
pre-dispatch secure-write revocation, durable lost-ACK hold across owner restart,
no duplicate submit, profile-bound journal recovery and external-stream cleanup.
The lost-ACK fixture intentionally drops an ACK; it is distinguished from the
normal official-backend probe, not passed off as a complete official lost-ACK run.

Initial first-slice ordinary suite (historical): **506 passed**; application coverage
**5297/5751 = 92.11%**, minimum unchanged at 85%. The final fatal-info/fatal-warning
analyzer was clean (one earlier analyzer run timed out under concurrent work;
its bounded foreground rerun passed). Normal-suite and official-backend tests
remain separate gates. Full ordinary-suite output is retained at
`/opt/data/cache/scratch/saathi-hermes-final-suite.log` outside tracked source.

## RED diagnoses retained, not hidden as backend limitations

- Initial canonical picker RED: only `stored` scope was requested. Official
  `session_listing.py` explicitly puts live canonical rows in the other scope.
  Both are now read; the actual official probe returns live=1, stored=0.
- Initial source harness used `ignore_user_config`, which **forces managed-worker
  execution**. Its stub was on the in-process boundary and could never own that
  worker. The fresh scratch profile now uses the normal canonical local policy,
  explicit empty toolsets and the stub execution boundary; no packaged backend
  route was changed and no real LLM ran.
- Initial attachment revocation compared two null session handles as equal,
  suspending the first attachment. The permanent selection guard now requires
  a non-null previously selected native session. The real-UI test caught this.
- The test originally used the last TextField during a route transition. It now
  waits for authoritative attachment and targets the actual `composer` key,
  preserving rather than bypassing the user-facing send path.
- Source import/runner initialization under concurrent Flutter work exceeded
  90 seconds **before ticket issuance** (safe stage timestamps show imports and
  authority ready, no ticket yet). The pre-mint harness-start budget is 180s;
  the real ticket's 30-second expiry, one-use property, client request budget and
  TLS checks are unchanged. Ready/cleanup failures no longer leak a child process
  or produce secondary late-initialization errors.
- Unit RED: external-client final snapshot left old streamed text mounted. It is
  now cleared after authoritative external resync, avoiding duplicate display.
- Unit RED: a secure-write suspension before dispatch became permanently unknown.
  Proven-not-dispatched work now removes its journal and returns to held FIFO
  recovery rather than claiming an uncertain inference.
- Unit RED: same source/session labels could load a journal from a different
  negotiated profile. Journals now bind the canonical profile and fail closed.

## Follow-on client work and fresh verification

This section supersedes the initial first-slice gaps and historical evidence
above. It **does not close #37/#38 or approve the transport for release**.

Implemented in the same unstaged delta:

- Actual ChatHome composer now mounts `CanonicalComposerControls`: Guide and
  Correct use generation-fenced native steer/redirect, separately from ordinary
  next-turn FIFO Send. Hard interrupt requests Stop then explicitly queues the
  retained draft; Stop ACK does not settle the running input. Rejected/stale or
  unconfirmed controls keep the draft. A real queued admission becomes running
  only on its exact owned execution delta, not arbitrary streamed activity.
- Compact native approval/clarification dialogs use the prompts discovered on the
  same authorized attachment, exact prompt identity/generation and advertised
  approval choices. `approval.respond`/`clarify.respond` are not inference POSTs.
  No action is auto-approved. Request events trigger read-only request resync.
  Unrecognized `open_requests` remain a host-review requirement; this is not a
  generic implementation of every optional server→client request type.
- A server advertising `session-transcript-v1` is resumed with `omit_messages:true`.
  The actual transcript uses oldest-order `rows`/opaque `next_cursor`/`reset`,
  `inline_images:false`, reads through an empty page, deduplicates durable row IDs
  plus row kind, and polls from its cursor. A reset replaces the previous lineage.
  Retained fields are visible text, public tool-name activity, compaction display
  summaries and exact submission identity—not reasoning sidecars, raw tool args
  or image data. This is automatic cursor pagination, not a latest-order history
  browser. A continuously changing read stops explicitly after 256 pages; it
  never silently labels a truncated snapshot complete.
- Lost ACK recovery first reads exact native pending `input_id` plus original
  session/profile ref, durably retains the recovered admission ID, then reads its
  receipt. Matching text is never attribution. Stored `display_metadata` with an
  exact `submission_id` proves that input landed; without a provable terminal
  receipt it still remains held/unknown. No recovery path resubmits a prompt.
- A prepared journal restores a never-dispatched held input, not uncertain work.
  Its secure journal remains present until dispatch. The controller imports it
  into the original session's paused FIFO with explicit Resume.
- Reconciliation locks dispatch before listener notification and retains the lock
  through durable history save. An authoritative final survives a storage failure;
  Try saving again uses the retained save closure without another native read or
  prompt. Pending resync events are retained while reconciliation is busy.
- Selecting B irreversibly revokes A's input/control authority, while a separate
  read-only observation path can save A's actual completion into A. It never
  changes the selected conversation or implicitly revives A input on return.

Fresh executed gates:

```sh
/opt/data/tools/flutter/bin/flutter test --no-pub --coverage --concurrency 2 --timeout 60s
python3 tool/check_coverage.py coverage/lcov.info --minimum 85
/opt/data/tools/flutter/bin/flutter analyze --no-pub --fatal-infos --fatal-warnings
/opt/data/tools/flutter/bin/dart format --output=none --set-exit-if-changed lib test
/opt/hermes/.venv/bin/python tool/hermes_canonical_probe.py
/opt/data/tools/flutter/bin/flutter test --no-pub test/integration/hermes_official_canonical.dart --timeout 240s
git diff --check
git diff --cached --binary | sha256sum
```

- Final normal full suite with the frozen shared transport: **575 passed**, normal
  assets, concurrency 2; coverage **5725/6268 = 91.34%**, unchanged 85% floor.
  Analyzer has no issues; format reports 144 files, zero changes. The original
  39-file staged seed SHA is unchanged.
- Real official WSS Python probe passes TLS, one-use/expired tickets, reconnect,
  deliberately unread admission ACK, new client socket, exact pending `input_id`
  receipt recovery and actual stored submission metadata read through one-row
  cursor pages. The stub now uses the official `persisted_user_metadata_for_event`
  under `submission_turn_scope`; it does not synthesize the stored submission ID.
  This is a client-socket restart, **not an official backend process restart**.
- Real Dart ChatHome/official backend test passes import→attach→composer→stream,
  actual Guide ACK, retained draft, controlled history-save failure and storage-only
  retry, external turn resync, A completion while B remains selected, and A→B→A
  no input revival. Test-only real HTTP overrides are removed/replaced solely in
  the test process. The issuer lifetime remains 30 seconds.
- Component widget tests exercise native busy choices plus a long approval dialog
  at 360px/2x with keyboard insets. They are not a substitute for the full combined
  ChatHome 360/390px matrix or an Android device.

Evidence retained outside tracked source:

- `/opt/data/cache/scratch/canonical-remaining-first-red.log`: exact pending-ID
  recovery returned false before implementation.
- `/opt/data/cache/scratch/canonical-metadata-red.log`: official persisted user row
  lacked submission metadata at the previous stub boundary.
- `/opt/data/cache/scratch/canonical-storage-red.log`: actual native final did not
  expose failed history persistence before storage-only retry was implemented.
- `/opt/data/cache/scratch/canonical-guard-full-suite.log`
- `/opt/data/cache/scratch/canonical-remaining-official-probe.log`
- `/opt/data/cache/scratch/canonical-guard-official-ui.log`
- `/opt/data/cache/scratch/canonical-fragment-red.log`: actual canonical client
  remained connected after 4 MiB of unfinished fragments before guard wiring.

The expanded real-network widget probe exposed fake-clock socket/ping lifetime
failures while waiting for external turns. The actual import button is now tapped
inside `tester.runAsync`, keeping network/socket timers on the real asynchronous
clock rather than changing production networking or weakening receipt/history
assertions. Two guarded official UI runs subsequently passed, including Guide,
storage-only retry, external turns and source-A completion while B is selected.
The raw-fragment fixture also closes its peer gracefully before teardown; abruptly
reentering the SDK iterator from peer destruction produced a fixture-only
`Future<bool>` type error. No shared helper bytes were changed for either fix.

## Remaining release/acceptance blockers — do not mark all #37/#38 complete

1. The **independently approved frozen shared WebSocket guard is now integrated**
   into the default native canonical dial. All six files match the immutable
   `saathi-ws-normalized-final.patch` manifest; patch SHA-256 is
   `a310192c8e250033900a46d4a0da6bd16ffce836fb5e6fa6cfe035c9b96caaf1`.
   `connectBoundedWebSocket` receives the original grant protocols, 3 MiB aggregate
   message budget (official ≤2 MiB transcript page plus envelope), 1024-fragment
   cap, request connect timeout and a source/authority-epoch cancellation signal.
   SDK TLS/handshake, actual-upgrade redirect rejection, compression-off and
   one-use host invitation checks are retained. Both actual-client fragmented RPC
   preservation around a nonempty ping and pre-FIN aggregate rejection pass; the
   shared 57 real-socket tests are included in the 575-pass ordinary suite.
   Independent approval of this module is **not approval of the full combined
   application**; parent still owns final union review and native acceptance.
2. The complete canonical lifecycle/failed-credential-write-at-start/delayed
   secure-write/Resume matrix is not finished. Existing source revocation and
   prepared-write tests pass, but the newer full acceptance combinations are
   not all exercised on the official backend.
3. The restored prepared journal → FIFO bridge must be reconciled with parent's
   corrected durable prepared-input implementation. This delta now deletes the
   exact canonical prepared journal before acknowledging FIFO cancellation, blocks
   Resume/dispatch during that secure delete, and retains the item if deletion
   fails. Parent's separate durable FIFO journal must participate in that ordering;
   do not drop either persistence barrier during integration. Preserve parent's
   false-write cache compensation, newSession selection pause, persona/media
   fences and 42-file fixes by delta.
4. Automatic cursor paging/reset is implemented, but latest-order browsing,
   stable reader anchoring across compression rewrites, wheel/trackpad live-follow
   arbitration and full 360/390px/2x actual-ChatHome approvals/long-draft layout
   remain acceptance work. Keep parent's critical selection/scroll fixes.
5. Official lost-ACK evidence now covers the actual pending and persisted metadata
   contracts over WSS, but not an official Dart journal-owner process restart at
   that boundary nor an actual backend process restart. The Dart owner-restart
   test is still a controlled WebSocket fixture. Late reconnect with only stored
   submission identity remains unknown rather than inventing terminal ownership.
6. No deployed public forwarding path, mobile login broker, native OS secure-store
   integration, Android build/device, paid provider or real user's Desktop session
   was exercised. The explicit host loopback-ticket/TLS-forwarding prerequisite
   above remains necessary and unchanged; no public broker was invented.

## Read-only installed source fingerprints

```
1c1b50581275266133df687d625c066a7095fcbbb78b878eb7b770866dd58308  gateway/runtime_bootstrap.py
e02f8840af46e7661b944a11d248ceeb88bc976f11642b94311df98993516da4  gateway/run_api.py
44624fbc34c86529db0963eb9dd2183b56b2c8034650053c6a6dc8c3556dc352  gateway/session_controls.py
7d18b6956a7df0200faa3b064b6c8746157e55b276b5d1e5c79ee2ee1ff23577  gateway/session_listing.py
28b860eb4a0b7acc554a564577bc0e52276e961b1a68b21813bf6cd7df664c77  hermes_cli/gateway_runtime_cli.py
4edfde2b7c5f62cf8bdf6aabc9fc39371153a2ea5f93e6910025f41090f32a21  hermes_cli/gateway_client.py
```
