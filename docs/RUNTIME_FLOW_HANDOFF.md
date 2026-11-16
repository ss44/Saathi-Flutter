# Hermes continuous conversation: runtime integration handoff

## Status / scope

This is an **integration-ready partial implementation**, not completion of all of
#37/#38. Keep it in the same integrated PR59. No commit, push, PR operation,
native build, deployed service, production credential or model inference was used.

Implemented vertical path:

1. Choose an existing externally-created **API-owned** server conversation in
   the real drawer/history UI.
2. Explicitly continue on its original connection and native Runs session ID.
3. Submit only `{input, session_id}`. Do not send history, instructions or a new
   model/provider override to an existing server conversation.
4. Render safe `message.delta` text through the **existing** activity SSE
   attachment. Read authoritative Runs status on completion; persist/commit via
   the existing journal and wake the existing FIFO scheduler.
5. Keep the composer usable. Send remains next-turn FIFO. Discovered native
   **Guide** is a different operation (`/steer`); acceptance does not prove the
   agent read it. **Stop** requests cooperative stopping and pauses the queue;
   it never claims cancellation before terminal status.

Original connection-map identity, authority epoch, secure-store scope, local chat
and operation key remain the fences. No parallel polling loop, second SSE
attachment or replacement inference queue was introduced.

## Reproduction and root causes

- The existing activity transport deliberately dropped `delta` from all SSE
  envelopes and the owner only updated telemetry. Consequently an actual
  server `message.delta` never reached the transcript, and `run.completed`
  did not trigger immediate result reconciliation. The UI could keep showing
  “thinking” with no visible streamed answer while status polling lagged.
- The controlled 360px / 2x-text / keyboard UI regression reproduced another
  concrete failure: the decorative native thinking block could occupy the live
  transcript edge, leaving **no response MessageView mounted** even after real
  output arrived. Native waiting is now a short factual waiting label, removed
  when actual response text is available. It does not imply private reasoning.
- A fresh control status read can discover completion before the ordinary poll.
  A dedicated failing localhost test reproduced a stranded queued follower;
  the control path now wakes the original scheduler after durable reconciliation.
- Explicit empty terminal output is committed as terminal, with “server finished
  without a text response” feedback; malformed/missing output remains unconfirmed
  and recoverable, never a synthetic answer or a resend.

## Verified native contracts / original-source boundary

Official documentation fetched from:

- `https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server`
- Existing canonical connection evidence: `docs/GATEWAY_API.md`.

Read-only installed server source inspected and exercised at `/opt/hermes`:

- `gateway/platforms/api_server.py`: original capability endpoint, exact
  `run_steer`, `run_stop`, Runs/status/events endpoint table.
- `gateway/platforms/api_server_runs.py`: `message.delta` uses `delta`, terminal
  event is `run.completed`, completed status supplies `output`; actual
  `/steer` accepts `{input}` and returns an `accepted` verdict; `/stop` returns
  `stopping` while work can still be executing.
- `gateway/session_api.py`: API-owned source binding and foreign-source fences.
- `tui_gateway/contracts/canonical_sessions.py`: canonical `session.resume`,
  `prompt.submit`, generation-fenced `session.steer` / `session.redirect`.

The installed source is not a Git checkout. Its exact SHA-256 identifiers, rather
than an invented upstream revision, are in [RUNTIME_SOURCE_EVIDENCE.md](RUNTIME_SOURCE_EVIDENCE.md).
The Android reference remains the read-only Hy4ri/hermes-mobile checkout pinned
to `008d9e88778ec3f7a70aab11af2b9917cf541c14`; its Queue/Guide/Correct/interrupt
modes are not interchangeable with a local FIFO.

## What the official-server probe establishes

`tool/hermes_controlled_server.py` imports the **original official**
`APIServerAdapter`, route table, SessionDB and Runs implementation from an
explicit read-only source directory. It replaces only agent construction with a
non-inferencing, checkpoint-controlled agent. It clears the subprocess
environment, uses a fresh empty HERMES_HOME under `.dart_tool`, fake local auth,
and binds an ephemeral loopback port. It does not launch a real model or tools.

The explicit Flutter compatibility probe drives ChatHome drawer → existing
server history → Continue → composer Send → actual server SSE text → native
Guide → final result. It then reads the exact server session history back and
asserts the same-session stored result. This is stronger than MockClient or a
hand-written HTTP-response fixture. It is **legacy API-server execution mode**,
not canonical TurnRunner/Gateway authority, a production gateway, or a device.

Run separately (not auto-collected in hermetic CI because source/venv are external):

```sh
/opt/data/tools/flutter/bin/flutter test --no-pub \
  test/integration/hermes_official_runtime.dart --timeout 180s
# Optional explicit read-only source / interpreter:
# HERMES_TEST_SOURCE=/path/to/hermes HERMES_TEST_PYTHON=/path/to/venv/bin/python
```

The ordinary suite additionally exercises real Dart localhost transports at
390px and 360px/2x-text with keyboard insets, retained draft, source-bound
completion, replay deduplication, malformed/empty output, restart/lost admission
ACK with identical journal bytes/key, cross-chat completion, owner disposal,
lifecycle and connection replacement during delayed secure reads. An idle-stream
test sustains real activity beyond the configured deadline, then stalls and
requires recovery. The deadline measures idle transport, not total run age.

## Genuine remaining blockers / unfinished acceptance

**Do not close #37/#38 on this patch alone.**

- Desktop/CLI/messaging sessions cannot be adopted through API-server Runs.
  Official docs explicitly refuse foreign REST execution; canonical source
  enforces original session authority. The existing gateway transport supports
  `session.resume` / `prompt.submit`, but **the app has no authenticated mobile
  bootstrap/grant broker wired to its connection settings or drawer**.
  `hermes gateway attach --json` is host-side and issues a fresh one-use grant;
  an API-server bearer key cannot mint it. No reachable trusted WSS grant/login
  was supplied, and guessing that conversion would violate the server contract.
  Required work is a verified host-issued grant/login/forwarding integration plus
  a lifecycle-bound canonical gateway UI/journal adapter, not removal of the
  server's foreign-source fence. This is an implementation/authentication gap,
  not a claim that canonical Hermes lacks participation.
- Canonical redirect exists, but Runs discovery exposes steer/stop, not a
  redirect endpoint. No guessed redirect route or hidden “supported” flag was
  added. Native Correct/redirect remains tied to the missing canonical path.
- API-owned initial history uses the existing bounded first-page preview;
  canonical multi-client transcript resync, large-history attachment and live
  external-client turns are not complete. The server still uses authoritative
  full session context; the phone never uploads that preview as model history.
- Direct-model one-shot behavior is unchanged. This patch does not claim every
  compatibility HTTP connection now streams or that every deployment symptom
  has been diagnosed without its transport logs.
- No native Android/device, real provider, deployed gateway or paid inference
  verification occurred. These are separate acceptance gates.

## Component-worktree verification (historical; not integrated totals)

- Normal Flutter suite with coverage: **441 passed**.
- Coverage gate: **4569 / 4833 executable application Dart lines, 94.54%**;
  required minimum remains 85%, with no new exclusions.
- Official-server / real-UI compatibility probe: **1 passed**, separately from
  the normal suite; exact same server history read back after completion.
- Fatal-info/fatal-warning analyzer: **no issues**; Dart format and
  `git diff --check` clean.
- One overly short localhost test deadline initially failed under parallel
  full-suite startup (zero events before headers). The activity test now allows
  realistic socket startup while still requiring every event, a stream lifetime
  longer than its idle deadline and subsequent idle disconnection. The full
  suite was rerun green; no assertion or application deadline was weakened.

## Integration ownership

The source-evidence document lists the official server hashes. Apply this delta to
base `22569571de45139055b8a0f4a5852b3f677bb3f8`; merge shared controller/home/storage
files by feature delta, preserving other worktrees' model tuple, optimizer,
media, OpenClaw, draft and parent/child UI contracts. Do not replace those files
wholesale from this worktree. Tests and formatting must be rerun after combining.
