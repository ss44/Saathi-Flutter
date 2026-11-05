# Project guidance

## Product direction
Iris is a clean, message-first Flutter client for a remote Hermes Agent setup. Android is the first-class initial platform; keep architecture portable to Linux and macOS.

## Working agreements
- Keep the interface simple and conversation-centered; use large, legible type and respect system text scaling.
- Group thinking and tool activity, keeping details expandable while surfacing approvals and errors.
- Shared text and images must be reviewed before sending.
- Work in separate Git worktrees; coordinate interfaces and shared files using `.agents/WORK_PLAN.md`.
- Treat credentials as secrets: never commit tokens; use secure platform storage in a real integration.
- Document assumptions and verify Hermes API/auth capabilities before implementing network integration.
- Run formatting, analysis, and tests when Flutter tooling is available.
