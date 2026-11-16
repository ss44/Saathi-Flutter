# Delivery and ownership

## Source of work

The repository is `ss44/Saathi-Flutter`. Use the user's current request and selected GitHub issues for scope. A backlog ticket does not authorize implementation. Keep the [product direction](../docs/PRODUCT_DIRECTION.md) current when the user approves a direction change; use [contributor guardrails](AGENTS.md) for delivery rules.

## Parallel work

Use an isolated worktree per unrelated task. Assign one owner to each working tree and an integration owner for changes that share files or contracts. Do not modify another contributor's worktree or a frozen integration baseline.

Agree adapter contracts before parallel implementation. Port only a feature's delta onto the current foundation; do not replace newer shared files with an older worker's copies. Recheck integration behavior after rebasing or merging.

Finish a dependency's correctness review before treating it as a ready foundation. A module with passing isolated tests is not a completed app feature until its real UI and adapter path work together.

## Completion bar

Run formatting, static analysis, the complete automated suite and configured quality checks. Exercise failure, storage, lifecycle and small-screen behavior where relevant. Obtain independent code review of the exact patch, require applicable CI, squash-merge and read back the result.

Record actual evidence and remaining gaps. Controlled HTTP tests do not certify a deployed backend; Flutter tests do not prove native secure-storage behavior, installation or phone acceptance. Keep source merges distinct from published releases. Do not dispatch a native build merely because a merge completed.
