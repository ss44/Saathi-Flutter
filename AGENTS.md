# Saathi project guidance

## Product direction
Saathi is a standalone, mobile-first Flutter companion for multiple AI models and agent backends. It is inspired by `ss44/sathi.ai`, not a DMS plugin or a Hermes-only client. Android first; shared domain/network/storage layers must remain usable on Linux and macOS. The spelling is **Saathi** (package `saathi`).

## Working agreements
- Keep chat central, readable, responsive, accessible, and respectful of system text scaling.
- Show observable activity while a request is running. On completed responses, reveal prior activity on swipe. Long-press copies response text. Never present hidden chain-of-thought as available telemetry.
- Keep approvals, errors, and terminal failure states visible; never silently approve a backend action.
- Separate direct-model/local history from server-owned remote sessions. Send only new input plus remote identity when supported. Never silently replay a foreign transcript or reroute an existing conversation to a different connection.
- Discover backend capabilities; do not infer an official API from the old QML adapters. Hermes REST cannot take over a live session owned by Desktop/CLI; that requires its gateway attach protocol.
- Credentials belong in platform secure storage, not ordinary settings, exports, history, logs, screenshots, or Git. Do not disable certificate verification. Non-loopback HTTP requires an explicit development exception.
- Updates must fail closed when release configuration is absent, reject downgrades/untrusted download locations, and respect platform installation consent. Never advertise a debug-signed artifact as a production release.
- Shared Android text/images must become reviewable drafts, never auto-send; intake remains a separate milestone until implemented and device-tested.
- Use test-first vertical slices: observe RED, implement GREEN, refactor. Run formatting, analysis, and full tests before handoff. State which native builds/real backends were actually exercised.

## Ownership during parallel development
See `.agents/WORK_PLAN.md`. Use exclusive directories with one integration owner for shared files; do not overwrite another active contributor. No repository creation or remote push until requested; the user will create the remote.
