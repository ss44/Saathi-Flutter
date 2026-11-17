# Organization application integration (#28 / #14)

## Scope and base

This work is in `integrate/organization`, based on the **frozen staged 39-file runtime/optimizer seed**, not just commit `2256957`. The seed's index blobs are preserved byte-for-byte. Additional changes are deliberately uncommitted and unstaged. Parent integration must apply the **index-to-working-tree additional delta** plus new organization files, not replace current integration files wholesale.

The later parent-only critical fixes (Guide/Stop selection and credential authority, remote continuation queue pause, wheel/trackpad reading position) were not copied into this worktree. Organization selection calls the existing `select()` path and metadata recovery wakes only the existing queue scheduler. Their exact combined result still needs parent review after merge.

## Implemented interaction

- Actual controller-lifetime organization store, all-original-chat activity mapping, stable completion IDs, serialized/durable unread and seen markers, and retained-authoritative-answer storage-only recovery.
- Native mixed Drawer with edge opening, physical Archive/Edit rail, accessible equivalent menu, explicit Archived/Restore view, existing local-content search plus renamed display titles, and matching app-bar names. Archive does not remove a session or stop observing work. Edit/archive do not clear a long draft.
- Real answer-body visibility, not row padding/navigation/poll acknowledgements. The owner disables visibility for drawer opening/dragging; the sentinel additionally checks foreground lifecycle, current route, offstage/opacity and every ancestor viewport. Only an already recorded completion can become read.
- Persistent reusable assistant roles through actual nested Edit dialogs. The original connection/model/session/history are not changed. Active, preparing, queued, uncertain and native-owned restrictions are checked for all attached chats at Save and retry, not only the selected chat.
- Captured immutable persona ID/revision/instructions before queue acceptance and credential awaits. Direct dispatch and held-head recovery use that snapshot. Native prepared journals retain it alongside their immutable payload. Existing native persona mutation stays unsupported; no invented endpoint, new native session or history replay is introduced.
- Bounded, explicit Direct prepared-input whitelist and source binding. A prepared head restores held; a dispatched/possibly executed head restores uncertain without automatic inference. Durable cancellation/abandonment is asynchronous and save-first. FIFO followers remain in-memory as disclosed by the existing queue UI. A prepared journal whose original source changed fails closed rather than rebinding to replacement credentials.
- Real normalized reported usage only. History persistence whitelists the three counters and the app-owned authoritative-completion flag, not raw usage/runtime maps. Anthropic missing counters remain absent, explicit reported zero remains zero, malformed counters are excluded, and no total is synthesized. Unsupported usage, percentages and pricing are hidden. Metadata recovery also gates optimizer entry/review authority.

## Tests and actual outcomes

Test-first RED/GREEN evidence was recorded under `/opt/data/cache/scratch/organization-*.log`: missing application controller API, absent app Drawer/visibility integration, fabricated Anthropic counters, metadata retry queue wakeup, empty terminal unread, native captured journal fields, waiting-for-approval state mapping, durable uncertain abandonment, replacement-source recovery, and optimizer entry while metadata is unsaved.

Additional application files:

- `test/organization_controller_integration_test.dart`: captured-role dispatch before credentials, all-chat statuses, source replacement, prepared recovery, uncertain abandonment, completion/save overlap, storage-only retry and usage/unread restart.
- `test/organization_home_integration_test.dart`: actual 360/390px keyboard/large-text drawer actions, title/search rename, restore rail, persistent persona creation, draft preservation, offscreen/drawer visibility and optimizer safety.
- `test/organization_native_integration_test.dart`: real loopback HTTP native admission/FIFO/completion, archive observation, metadata failure/retry, immutable captured journal, no history replay and no empty-output unread.
- `test/organization_usage_core_test.dart`: actual provider translation with absent/partial/zero/malformed/full Anthropic counters.
- Existing `test/chat_stabilization_integration_test.dart`: now jointly exercises actual organization rename/archive and unsupported native persona UI alongside live child activity, streamed output, approval, long draft and optimizer Apply/Undo at 360/390px, 2× text and keyboard insets.

Final individual gate results:

| Command | Actual result | Evidence under `/opt/data/cache/scratch/` |
| --- | --- | --- |
| `flutter analyze --no-pub --fatal-infos --fatal-warnings` | exit **0**, no issues | `organization-analyze-postfix.log` |
| `dart format --output=none --set-exit-if-changed lib test` | exit **0**, 146 files, 0 changed | `organization-format-postfix.log` |
| Focused application/component/critical regression gate below | exit **0**, **99 passed** | `organization-focused-final.log` |
| Complete normal Flutter suite before the final test-fixture correction | exit **1**, **533 passed / 1 failed** | `organization-full-final.log` (RED retained) |
| Entire corrected actual-ChatHome test file | exit **0**, **5 passed** | `organization-visibility-final.log` |

The full-suite failure was specifically the new visibility test's illegal test-driven lifecycle jump `resumed → paused`, rejected by Flutter's `AppLifecycleListener`; it was not an analyzer or formatting failure. The fixture now traverses `resumed → inactive → hidden → paused` and the valid reverse sequence. It proves a visible answer behind the drawer/background remains unread and becomes read only after foreground resume. The subsequent 99-case gate includes the corrected test, real native HTTP queue/metadata recovery and the expanded joint small-screen test. No additional full rerun was started while the parent's independent critical full suite was active; **there is no claim of a complete green normal suite for this final worktree**.

Focused command (SDK prefix `/opt/data/tools/flutter/bin/`):

```sh
flutter test --no-pub \
  test/organization_controller_integration_test.dart \
  test/organization_home_integration_test.dart \
  test/organization_native_integration_test.dart \
  test/organization_usage_core_test.dart test/chat_organization \
  test/runtime_flow_test.dart test/runtime_recovery_test.dart \
  test/chat_stabilization_integration_test.dart test/send_optimizer_menu_test.dart \
  test/ui/dispatch_ownership_test.dart test/ui/queued_safety_test.dart \
  test/core/provider_protocol_test.dart --reporter expanded
```

During integration, the normal suite exposed an artificial pending journal-tail Future created in a fake-async widget construction zone. The journal now starts its first write directly and serializes subsequent writes, preserving the original end-to-end demo tests without weakening their assertions. An initial full-suite attempt was interrupted by the tool's 420-second execution cap after 526 passing cases; it was not reported as a complete pass.

Existing regression expectations were changed only where the contract genuinely changed: provider usage no longer invents Anthropic totals, and durable cancel/abandon callers now await save-first completion. A direct dev dependency on `shared_preferences_platform_interface` makes the copied false-preference-write test's import explicit.

## Limits and remaining integration

No commits, pushes, PRs, releases, production keys, paid calls, signing, native builds or device tests were performed. Controlled HTTP tests prove application/adapter behavior, not deployed native persona mutation or Android secure-storage behavior. Native persona mutation remains deliberately unsupported. Parent must merge this additional delta with its independent critical fixes and other vertical feature deltas, then review/retest the exact combined tree. No coverage percentage is claimed by this workstream; parent owns the final combined coverage gate.
