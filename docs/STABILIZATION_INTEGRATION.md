# Chat stabilization integration — umbrella 59

## Delivery state

Uncommitted working artifact on `stabilize/integration`, base `22569571de45139055b8a0f4a5852b3f677bb3f8`. This is a **partial umbrella implementation**, not completion of all nine issues, a stable-release claim, a published app, or a PR/merge. No component worktree was modified. Shared runtime and optimizer files were merged by their feature deltas against the immutable base, not snapshot overwrite.

## Actually integrated into ChatHome

- Native Runs receives actual `message.delta` through the existing activity SSE attachment; terminal events trigger the existing status/journal reconciliation and FIFO wakeup, rather than adding another stream or inference path. Empty terminal output, malformed output, disconnect, lost acknowledgement/restart and durable-save recovery remain distinct.
- The real drawer can continue an API-owned existing conversation on its original connection/session ID. Subsequent Runs submission contains only `input` and `session_id`, never preview history, model/provider overrides or local instructions.
- Capability-discovered Guide and Stop use the original verified native endpoints. Guide is checkpoint input, not another turn or proof it was read. Stop pauses queued followers and remains pending until authoritative terminal status.
- Optimizer 29+34: hidden Send menu, global/per-chat destination ownership, grouped verified model selection, explicit Original/Improved review, Apply/Keep/Undo, source/setting/draft/session/lifecycle fences. No response-model mutation, history leakage, tool/agent execution or automatic send.
- Final-29 late fixes were independently compared and retained: a disabled/busy hold cannot fall through to Send; merged custom semantics and keyboard alternatives; permanent menu revocation across a session round trip; mounted review/Undo across keyboard changes. The final-29 unsupported-native test now asserts the new destination review's Improve button is disabled rather than absent; it still requires an explanation and zero requests.
- New combined localhost actual-ChatHome regression at **both 360 and 390 pixels, 2x text, keyboard open, pending approval, child activity, live text and long draft**. It exercises reachable approval/Stop/Guide, zero extra inference for approval, hold safety, durable completion, then separate optimizer Improve/Apply/Undo through the same mounted home and keyboard transitions.
- OpenClaw domain/secure-secret foundations and exploration documentation only. Its provider, pairing/signing/transport UI and native controls remain disabled/unfinished. No organization or media widgets/modules/native changes were copied into the app or exported as finished features.

## Reproduced failures and fixes

1. `flutter test --no-pub test/runtime_delta_integration_test.dart --reporter expanded` exited **1** against the base runtime: expected `visible reply`, got `null`. The same test is now green and remains in the full suite.
2. `flutter test --no-pub test/send_optimizer_menu_test.dart --reporter expanded` against runtime+initial-34 exited **1**: holding busy Send cleared the draft/queued work and Send lacked the custom semantics action. Final-29 gesture/semantics deltas fixed both; session-round-trip and keyboard ownership regressions also run.
3. `flutter test --no-pub test/chat_stabilization_integration_test.dart --reporter expanded` reproduced **2 failures**: optimizer opened during real native approval-waiting work because `busy` was false even though `runPending` was true. Entry/review now fences both. The command then passed **2 tests**.
4. The official-server probe initially failed only its request-settlement teardown assertion after all same-session stream/control/history assertions passed. The test had disposed ChatHome and waited solely with real delays, without pumping fake-scheduler continuations. It now drains both widget scheduling and actual I/O before owner disposal, retaining the settlement assertion and authoritative history readback; the probe passed.

Initial fixture-construction problems (an unavailable new constructor argument, a mismatched fake session ID and overlapping HttpResponse flushes) were corrected separately and are not counted as application RED evidence.

## Pre-review integration command results

These commands ran before the four independent-review findings below were fixed; they are historical evidence for the initial critical slice, not final approval of its corrected successor. `flutter`/`dart` below were the absolute `/opt/data/tools/flutter/bin/` executables. Normal tests retained assets; no test skips or coverage exclusions were added.

| Command | Actual result |
| --- | --- |
| `/opt/data/tools/flutter/bin/flutter test --no-pub --coverage --timeout 60s --reporter expanded` | exit 0; **496 tests passed** (normal full suite, after final app/asset changes) |
| `python3 tool/check_coverage.py coverage/lcov.info --minimum 85` | exit 0; **5062/5339 = 94.81176250234126240869076606%**, minimum 85% |
| `/opt/data/tools/flutter/bin/flutter test --no-pub test/integration/hermes_official_runtime.dart --timeout 180s --reporter expanded` | exit 0; **1 test passed**, original official server implementation, deterministic non-inferencing agent, exact same-session history read back |
| `/opt/data/tools/flutter/bin/flutter analyze --no-pub --fatal-infos --fatal-warnings` | exit 0; **No issues found** |
| `/opt/data/tools/flutter/bin/dart format --output=none --set-exit-if-changed lib test` | exit 0; **131 files, 0 changed** |
| `python3.13 -m venv .venv` and `.venv/bin/python -m pip install -r tool/requirements-test.txt` | exit 0; pinned Pillow 13.0.0 installed into isolated Python 3.13 venv |
| `.venv/bin/python -m unittest discover -s tool -p 'test_*.py' -v` | exit 0; **107 tests passed**, including workflow/release guards |
| `.venv/bin/python -m unittest discover -s test/branding -v` | exit 0; **1 test passed** |
| `PR_TITLE='CHAT: Integrate continuous chat and prompt optimization' .venv/bin/python tool/check_pr_title.py` | exit 0; **PR title format is valid**; no PR was created |
| `git diff --check` | exit 0; clean |

`actionlint` is not installed/on PATH and was not run. No workflow YAML, native platform source, dependency manifest, core provider translation, update validation or signing configuration was changed. Existing workflow guards passed inside the tooling suite; this is not a remote CI result.

Local evidence logs are outside the repository under `/opt/data/cache/scratch/saathi-integration-*.log`: `delta-red`, `optimizer-red`, `optimizer-green`, `runtime-green`, `combined-red`, `combined-green`, `official-red`, `official`, `full-final`, `tooling`, and `branding`. Runtime source hashes and precise controlled-backend limits are in [RUNTIME_SOURCE_EVIDENCE.md](RUNTIME_SOURCE_EVIDENCE.md).

## Independent review and correction cycle 1

Independent review rejected the initial snapshot after reproducing delayed native controls surviving credential replacement or a conversation round trip, missing queue-switch pause on a new remote continuation, and live output overriding a mouse-wheel reader's position.

The corrected controller uses mutation-start control revisions and irreversible selection generations, and selects a persisted remote continuation through the existing queue-pause path. Scheduled live-follow frames are bound to their source, operation, selection and scroll revision; wheel, trackpad, drag and ballistic reading gestures revoke following without disabling the live edge.

The three new regression files below passed 15 focused tests in a fresh parent run. The first post-fix full-suite attempt was terminated by the tool's 420-second limit after 421 completed tests; it is not a passing full-suite result. Fresh full verification and exact independent re-review remain required. The interrupted fix worker's earlier unused-import analyzer warnings were removed before handoff; analyzer acceptance must still be rerun.

## Explicitly remaining / not integrated

- **37/38 canonical Desktop/CLI/messaging attachment stays open.** The existing canonical transport needs authenticated host-issued grant/login/bootstrap wired into connection settings/drawer and a lifecycle-bound UI/journal adapter. An API bearer key cannot mint that grant. No fake unsupported completion, guessed redirect endpoint or history-cloning workaround was introduced.
- API-owned continuation is proven, not all-client concurrent transcript resync or large canonical-history attachment. Direct-model UI streaming and scrolled-up new-message feedback are not completed by this patch.
- **28/14 organization/personas/read visibility/usage are not integrated.** Their controller completion/outbox persona snapshots, actual mixed drawer/appbar titles, visibility/occlusion acknowledgement, stable completion identity and usage wiring still need complete app vertical slices. The component's noted Anthropic missing-usage provenance defect remains unfixed because no usage UI was enabled and the original provider code/tests were preserved.
- **7/9 media/share are not integrated.** Actual Send exclusivity, source authority, result/history storage-only retry, Android ShareDraftBridge and independent global image-connection selection remain to be wired and exercised together. No unfinished media control, provider upload path, plugin/native change or extra dependency was enabled.
- **16 OpenClaw app integration remains NO-GO.** Domain/storage tests pass; native Dart WebSocket adapter, audited signer, pairing UI, receipt recovery and app/device flow are not finished. The exploration document's real-Gateway results are component research evidence, not a rerun through Flutter here.
- Independent security/logic/user-flow review, actual GitHub CI, one cohesive umbrella PR and squash merge remain parent-owned. No commit, push, PR creation, release dispatch, production secret, private signing material or paid request was used.
- No APK/native desktop build, physical device, screen-reader device, deployed user gateway, actual secure-storage backend or production provider inference was verified. Current beta/stable publication state was not changed.

## Owned files

The following is the exact integration-owned changed/new file set. The pre-existing untracked `.agents/STABILIZATION_ACCEPTANCE.md` was read and preserved untouched, and is not attributed to this integration writer.

- `assets/changelog.json`
- `docs/OPENCLAW_EXPLORATION.md`
- `docs/PROMPT_OPTIMIZER.md`
- `docs/RUNTIME_FLOW_HANDOFF.md`
- `docs/RUNTIME_SOURCE_EVIDENCE.md`
- `docs/STABILIZATION_INTEGRATION.md`
- `docs/UI_DECISIONS.md`
- `lib/agent_activity/activity_owner.dart`
- `lib/agent_activity/activity_transport.dart`
- `lib/agent_runs/run_client.dart`
- `lib/openclaw/openclaw_domain.dart`
- `lib/openclaw/openclaw_secrets.dart`
- `lib/storage/saathi_store.dart`
- `lib/ui/chat_controller.dart`
- `lib/ui/chat_home.dart`
- `lib/ui/connections.dart`
- `lib/ui/optimizer_review.dart`
- `lib/ui/optimizer_settings.dart`
- `lib/ui/prompt_optimizer.dart`
- `lib/ui/remote_sessions.dart`
- `test/agent_activity/activity_transport_test.dart`
- `test/agent_run_home_safety_test.dart`
- `test/chat_stabilization_integration_test.dart`
- `test/integration/hermes_official_runtime.dart`
- `test/independent_control_authority_test.dart`
- `test/independent_multi_run_test.dart`
- `test/openclaw/openclaw_domain_test.dart`
- `test/openclaw/openclaw_secrets_test.dart`
- `test/optimizer_authority_test.dart`
- `test/optimizer_draft_authority_test.dart`
- `test/optimizer_http_test.dart`
- `test/optimizer_settings_test.dart`
- `test/optimizer_settings_ui_test.dart`
- `test/prompt_optimizer_acceptance_test.dart`
- `test/prompt_optimizer_test.dart`
- `test/runtime_delta_integration_test.dart`
- `test/runtime_flow_test.dart`
- `test/runtime_recovery_test.dart`
- `test/runtime_scroll_authority_test.dart`
- `test/send_optimizer_menu_test.dart`
- `tool/hermes_controlled_server.py`
