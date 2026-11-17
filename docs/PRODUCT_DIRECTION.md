# Saathi product direction

## North star

Build a lightweight, conversation-first client that makes real agent work approachable. Hermes is the primary native-agent compatibility target. Saathi began as a lighter Hermes client and is growing toward Sathi's multi-agent feel, while remaining a standalone Flutter app with direct-model connections.

A person should be able to choose a connection, have a conversation, understand what is happening, and act when their input is needed. They should not need to understand a backend protocol to use the app.

This document records product direction, not a claim that every feature below has shipped. The [specification](SPEC.md), adapter contracts, reviewed changes and released builds establish implementation status.

## Two connection types

| Type | Responsibilities |
|---|---|
| Direct model | Translate provider inference requests, manage the conversation context in the app, and expose the provider's supported model options. |
| Native agent client | Use a backend-specific adapter for server-owned sessions, jobs, recovery, controls and activity. Hermes comes first; OpenClaw has its own adapter and verified feature set. |

Share useful UI and domain concepts, not invented transport semantics. Do not make every backend look like a plain model, and do not give direct models controls that require an agent runtime. Saathi is a client, not a claim that the phone runs a local tool-executing agent.

## Per-connection features

Behavior follows the configured agent's verified feature list. Depending on the adapter and server, this may include model discovery, remote history, session continuation, reconnect, approvals, clarification, event streams or sub-agent activity.

- Distinguish supported, unsupported and unknown features. Failed discovery does not prove support or lack of support.
- Bind discovery and operations to the original connection, server/profile and authority. A familiar provider name or run ID is not enough.
- Show controls only when the adapter and server support their contract. Explain unavailable features where useful.
- Keep backend differences inside their adapters. New support must not weaken an existing adapter's guarantees.
- Feature parity is not required. A richer Hermes experience can coexist with simpler connections.

## Product values

- Keep chat central. Use compact controls and short, everyday wording rather than an administration dashboard.
- Show actual work and actionable waiting states. Never invent progress, children, answers or hidden reasoning.
- Preserve conversation ownership. Do not silently replay a foreign transcript or transfer it to another connection.
- Ask before consequential actions. Approval is explicit; an accepted job is not a completed answer.
- Protect credentials and private history. Recovery must not accidentally repeat work.
- Respect small screens, larger text, keyboards and accessible controls.
- Prefer a reliable complete interaction over a larger set of disconnected components.

## Delivery decisions

Finish one observable interaction at a time: UI action, adapter request, authoritative result, persistence and recovery. Build shared components only where the contracts really match. Keep direct-model behavior working as native-agent support grows.

A test fixture, a deployed server, a native build and a real device prove different things. Report which were exercised. Keep merged source separate from the features in a published binary.

New ideas belong in the backlog until selected. A ticket is not permission to implement it; merge permission is not permission to release it.

## Keep this direction current

Update this document in the same PR as an approved change to product direction. Record the decision and reason below, then reconcile the specification and relevant adapter documentation. Do not silently change the product goal to fit a partial implementation.

### Decisions

- 2026-11-16: Confirm Hermes as the primary native-agent target and Sathi's multi-agent feel as the broader direction. Separate direct models from native agent clients, with behavior driven by each configured connection's verified features.
- 2026-11-17: Run native releases daily at 09:00 UTC rather than weekly, so approved changes reach users sooner. Keep the unchanged-source skip, ISO year.week.increment versioning, signing and publication gates; do not build on every merge.
- 2026-11-17: Extend the shared Flutter client with a Linux-first adaptive workspace. Wide desktop and landscape windows use a far-left navigation rail, a persistent conversation list and the active conversation on the right; narrow windows retain mobile navigation. Windows and macOS can share this layout, with platform acceptance verified separately.
