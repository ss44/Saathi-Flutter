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

## Pull requests and delivery

Use the exact title shape **`<DOMAIN>: <summary>`**. Use a short uppercase domain for the area changed and a clear summary, for example:

- `HERMES: Reconnect jobs without repeating input`
- `CHAT: Preserve queued messages after a save failure`
- `DOCS: Record product direction and contributor guardrails`

Keep each unrelated issue on its own branch and PR. Read the issue and discussion, define acceptance criteria and use an isolated worktree for parallel work. One owner integrates shared files.

Describe the behavior, tests actually run and remaining limitations in the PR. Bind review and CI to the exact head revision. Under the user's standing authorization, squash-merge only after applicable checks and review pass, then verify the merge and issue state. Never force-push, bypass protections or directly push a fix to main without explicit permission.

Native releases run daily at 09:00 UTC or when explicitly requested, skipping unchanged source. Merging a PR does not authorize an extra release. Report clearly whether a published binary includes the change.
