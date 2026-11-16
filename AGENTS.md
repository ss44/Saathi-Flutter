# Saathi project guidance

Before changing any file, read [.agents/AGENTS.md](.agents/AGENTS.md) and [the product direction](docs/PRODUCT_DIRECTION.md). The guardrails apply across this repository, not only inside `.agents/`.

## Product direction

Saathi is a standalone, mobile-first Flutter client. Hermes is the primary native-agent compatibility target; the broader direction follows Sathi's multi-agent feel. Keep direct-model inference separate from native agent-client adapters. Each configured connection's verified features determine its behavior and controls.

Keep chat readable and simple. Preserve original conversation ownership, explicit consent, secure credentials and truthful activity. Never invent progress, hide uncertain outcomes, replay foreign history or call a fixture a live backend result.

## Working agreements

- Follow the SOLID, naming, documentation, test and quality rules in `.agents/AGENTS.md`.
- Use PR titles in `<DOMAIN>: <summary>` form. Keep unrelated changes in separate reviewed PRs and squash-merge only after applicable checks pass.
- Use isolated worktrees and one integration owner for shared files; see [.agents/WORK_PLAN.md](.agents/WORK_PLAN.md).
- Use test-first slices and controlled network fixtures. Report native build, real-server and device verification separately.
- Keep credentials in platform secure storage, never source, ordinary history or logs. Preserve TLS and updater validation.
- Shared Android text/images must become reviewable drafts, never auto-send; intake remains separate until implemented and device-tested.
- Keep releases weekly or explicitly requested. Merge authorization is not release authorization.
