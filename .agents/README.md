# Agent workspace

Start with [the contributor guardrails](AGENTS.md), [product direction](../docs/PRODUCT_DIRECTION.md) and [delivery ownership](WORK_PLAN.md). The root `AGENTS.md` makes these rules applicable across the repository.

Keep durable product decisions in `docs/PRODUCT_DIRECTION.md`, technical contracts in the relevant adapter documents, and task scope in GitHub issues and PRs. Do not duplicate a temporary task list here or overwrite another worktree's changes.

## Continuing audited work

The [issue 68 report](../docs/audits/2026-11-17-codebase-audit.md) records the exact
audited revision/model, confirmed and rejected findings, fix disposition, checks
and remaining work. Its [path manifest](../docs/audits/2026-11-17-coverage.md)
accounts for reviewed text, generated wiring and exclusions. Start there for
context, then inspect the current code and regression tests; do not treat baseline
line numbers or old handoff verdicts as current implementation status.

Use `AGENTS.md` for durable invariants and `STABILIZATION_ACCEPTANCE.md` for the
remaining integrated/device gates. Audit permission alone does not authorize
fixes, merge or release. The current user's explicit scope controls each task;
historical release permission must never be reused.
