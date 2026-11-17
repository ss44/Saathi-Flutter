# Contributor and agent guardrails

These rules apply to the whole repository through the root [AGENTS.md](../AGENTS.md). Read the [product direction](../docs/PRODUCT_DIRECTION.md) before changing behavior; use the [specification](../docs/SPEC.md) and adapter documentation for detailed contracts.

## Product boundaries

Hermes is the primary native-agent compatibility target. Preserve the lightweight chat experience and the broader Sathi-inspired multi-agent direction.

Keep direct-model inference separate from native agent-client contracts. Hermes and OpenClaw need their own adapters; their configured feature sets determine supported UI and behavior. Do not invent endpoints, hide unsupported states, imply feature parity or substitute read-only history for requested interactive chat.

## Code design

Follow SOLID principles without adding abstraction for its own sake:

- **Single responsibility:** give a class or method one clear responsibility. Separate UI, transport, protocol translation, persistence and orchestration as their responsibilities grow.
- **Open/closed:** add provider behavior behind adapter boundaries rather than spreading provider conditionals through shared UI.
- **Liskov substitution:** implementations must honor their interface's success, failure, cancellation and ownership guarantees. An admission acknowledgement cannot stand in for a completed reply.
- **Interface segregation:** expose small feature interfaces. A model adapter should not implement meaningless job-control methods.
- **Dependency inversion:** depend on explicit contracts at network, storage and platform boundaries so tests can supply controlled implementations.

Prefer the simplest design that meets the requirement. Keep methods focused and nesting shallow; make side effects and asynchronous ownership clear. Prefer typed boundary models over passing unchecked maps between layers. Do not split a small method into layers of single-use wrappers merely to satisfy a slogan.

Use clear, concise names that describe intent. Prefer `connection`, `operation` and `pendingMessages` to opaque abbreviations. Standard terms such as `id` and `url` are fine. Do not hide mutable state or side effects behind vague method names.

Keep naming cleanup and structural refactors scoped. Do not turn an unrelated fix into a broad rewrite; use a separate reviewed PR when cleanup crosses the task boundary.

## Documentation

Document public APIs and non-obvious behavior clearly and concisely. Explain inputs, results, failure and cancellation behavior, side effects and ownership where they affect callers. For asynchronous work, document revocation, lifecycle and persistence guarantees.

Use Dart documentation comments for public contracts. Comments should explain why a decision exists rather than repeat the next line of code. Update adapter documentation when wire behavior changes and the product-direction document when approved goals change. Avoid stale implementation claims and redundant copies of the same policy.

## Tests and quality

Use test-first vertical slices: observe a meaningful failing test, implement the smallest fix, then run the relevant regression tests and full suite. Assert user-visible behavior and failure paths, not only mocks or happy-path results.

Require at least **85% line coverage** for application Dart code. Coverage checks must fail when the report is missing or invalid. Do not silently lower the threshold, hide uncovered application files, or exclude difficult code to raise the percentage. Measure and report the baseline; if a future change falls below the floor, add meaningful tests before merging. Coverage does not replace tests of critical behavior.

Require regression coverage for request duplication, uncertain outcomes, credential/source changes, storage failure, lifecycle interruption and capability gating when those paths change. Exercise actual small-screen controls with large text and keyboard insets for UI changes.

Formatting, static analysis, automated tests and the configured coverage checks belong in CI. Do not suppress analyzer rules, weaken assertions or skip tests to get a green build. Explain any narrow, necessary exception in the PR. SOLID, meaningful names and useful documentation also require human review; a linter cannot prove them.

Keep production credentials and paid requests out of automated tests. Controlled HTTP/widget tests, deployed-server compatibility and native-device acceptance are distinct evidence.

## Regression invariants

The [pinned audit and disposition](../docs/audits/2026-11-17-codebase-audit.md)
records the evidence behind these requirements. Apply them at the actual UI,
storage and transport boundaries, not only through isolated helper tests:

- Keep invalid or orphaned uncertain operations bound to their original authority. Retain recovery evidence, never replay automatically, and do not make an unrelated healthy conversation unusable because one operation needs recovery.
- Exercise persistence limits through normal growth, not only malformed-input parsing. A full metadata ledger must not masquerade as a retryable disk failure or silently evict identities needed for deduplication.
- Treat preferences caches and durable storage as distinct. Test false returns, thrown writes, reconstruction, and process-death snapshots between credential and metadata writes. Never pair old authority metadata with a replacement secret.
- All conversation-selection surfaces must revoke stale dispatch consistently. Drafts, pending text, waiting indicators, queue controls and delayed callbacks remain owned by their originating conversation, including notification and activity navigation.
- Validate accepted input against the same bounds used by persistence and restore. Cleanup must cover synchronous exceptions as well as failed futures. Bound cumulative streaming retention, not only individual frames, and release settled ownership references.
- Show the actual action separately from approval description. Unreviewable affirmative actions fail closed; denial stays available. Preserve backend-advertised choice semantics rather than assuming native and HTTP contracts are identical. Stop and explicit interrupt-then-queue are distinct interactions.
- Provider changes must not silently transfer conversation history. Exact-byte replay tests must contain genuinely noncanonical stored bytes; privacy tests must assert their supposedly private history is nonempty before exercising exclusion.
- Multiple app processes must not independently overwrite whole-state storage. Updater consent binds the reviewed version/build as well as bytes, package and signer. Release provenance binds the actual resolved tag to the built commit, not only mutable release metadata.

Do not delete a documented/exported API or an intentional deferred prototype solely
because a search finds no app caller. Corroborate usage and compatibility first.
Keep generated integration wiring distinct from authored code, and preserve
historical evidence with explicit revision/status labels rather than rewriting it.

## Pull requests and delivery

Use the exact title shape **`<DOMAIN>: <summary>`**. Use a short uppercase domain for the area changed and a clear summary, for example:

- `HERMES: Reconnect jobs without repeating input`
- `CHAT: Preserve queued messages after a save failure`
- `DOCS: Record product direction and contributor guardrails`

Keep each unrelated issue on its own branch and PR. Read the issue and discussion, define acceptance criteria and use an isolated worktree for parallel work. One owner integrates shared files.

Describe the behavior, tests actually run and remaining limitations in the PR. Bind review and CI to the exact head revision. Under the user's standing authorization, squash-merge only after applicable checks and review pass, then verify the merge and issue state. Never force-push, bypass protections or directly push a fix to main without explicit permission.

Native releases run daily at 09:00 UTC or when explicitly requested, skipping unchanged source. Merging a PR does not authorize an extra release. Report clearly whether a published binary includes the change.
