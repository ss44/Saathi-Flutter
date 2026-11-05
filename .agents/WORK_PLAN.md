# Iris — parallel delivery plan

Status: planning. No workstream below has been assigned or completed. Android is the first target; Linux and macOS remain supported architectural targets, with tray behavior deferred.

## Product guardrails

- Chat is the main event: generous, readable text, calm spacing, minimal chrome, and respect for system font scaling.
- Thinking and tool activity remain available but grouped, unobtrusive, and expandable. Never silently hide approval requests, errors, or safety-critical status.
- Sessions are easy to find without becoming a control panel.
- Android shares of text and images land in a reviewable draft; never auto-send shared content.
- A server URL and authentication are required for real Hermes integration. Never log or commit credentials. Clearly label mock behavior and unsupported capabilities.

## Coordination rules

1. The integration owner establishes and maintains public interfaces, app composition, dependency versions, platform runner configuration, and shared CI. Feature agents work in separate Git worktrees/branches from a committed baseline; do not run concurrent edits in the same working tree.
2. Agents own the directories listed below and must not modify another track's files without coordinating. Submit interface/dependency/manifest requests to the integration owner rather than editing shared files independently.
3. Before coding, each agent reads `AGENTS.md`, `docs/SPEC.md`, this plan, and any agreed interface contracts. Use test-first development and report actual commands, outcomes, risks, and unresolved decisions. Do not claim unrun platform tests passed.
4. Each track opens a small, reviewable change with tests and a short integration note. The integration owner reviews and merges one at a time, reruns the complete suite, and resolves contract or generated-file conflicts centrally.
5. No secrets, personal chat content, or live server credentials in fixtures, logs, git, screenshots, or agent reports. Use fake credentials and a local mock server for tests.

## Workstreams

| Track | Owned files / boundary | Deliverable | Dependencies and verification |
|---|---|---|---|
| **0 — Integration and contracts** | `lib/main.dart`, `lib/src/app/`, `lib/src/contracts/`, `pubspec.yaml`, platform runners, shared CI | App composition, stable models/interfaces for chat/session/connection/share, dependency policy, integration reviews. Owns cross-track changes. | Establish interfaces before implementation tracks bind to them. Run `flutter analyze` and `flutter test` after each merge. Platform builds only on hosts with the relevant SDK/toolchain. |
| **A — Chat experience** | `lib/src/chat/`, corresponding `test/chat/` | Responsive message-first interface, large readable text, streaming/loading/error states, compact expandable activity, composer and session entry. Use injected fake services until integration. | Agree contracts with 0; widget tests for scaling, accessibility labels, states, expansion and composer. No claim of live Hermes chat until connected. |
| **B — Hermes integration** | `lib/src/hermes/`, corresponding `test/hermes/` | Adapter for the verified official server contract, including supported chat streaming, cancellation/session behavior and meaningful error states. | Verify current docs and actual server capabilities with 0 before selecting endpoints. Test against a deterministic local mock server, including disconnects, auth failures and duplicate-submission risks. Live-server test requires user-approved endpoint and credentials. |
| **C — Sessions and local data** | `lib/src/sessions/`, corresponding `test/sessions/` | Session list, creation/switching and persistence behind an interface. Define local-cache vs server-source-of-truth behavior, recovery and deletion. | Coordinate session IDs/history with B and UI with A. Tests for round-trip persistence, isolation, deletion and failure recovery. Storage choice and retention need review; no secrets in session storage. |
| **D — Connection and security** | `lib/src/connection/`, corresponding `test/connection/` | Simple server URL/auth setup, validation, connection/error states and secure credential storage. | Confirm auth with B; coordinate dependencies with 0. Tests for validation, HTTPS policy, secret redaction and secure-storage failure. Never disable TLS verification. |
| **E — Android share intake** | `lib/src/share/`, `android/` share implementation, corresponding `test/share/` | Handle incoming text/images on cold and warm launch, place them into a draft for review and consent; coordinate session selection and preserve input safely. | 0 owns manifest/dependency merges; agree a single platform-channel/plugin strategy first. Test intent MIME handling, permissions/URI lifetimes, invalid content, duplication, cancellation and no automatic send on an Android device/emulator. |
| **F — Accessibility and release QA** | `docs/qa/`, `integration_test/` after coordination with 0 | Cross-platform test plan and executable end-to-end checks where host tooling permits; accessibility and privacy review. | Start early on acceptance scenarios; exercise merged work on Android, with TalkBack, larger fonts, keyboard/rotation and network failure. Report gaps, not assumed passes. Linux/macOS tray is a separate future milestone. |

## Order of operations

1. **Baseline:** install Flutter, generate Android/Linux/macOS runners without overwriting project code, add a minimal smoke test, document available/missing host tools, and establish a committed baseline when the user wants one.
2. **Contracts:** integration owner agrees small interfaces and capability semantics with A–E. Agree ownership of shared dependencies and Android manifest edits. Server API and secure storage are verified, not guessed.
3. **Parallel delivery:** A can build against fakes while B, C, D, and E implement independent adapters; F writes acceptance scenarios and tests. Resolve cross-track questions in the contract, not by duplicating state.
4. **Integration:** merge in small increments; verify chat, connection, session continuity and share-to-draft together. Test without secrets and label any unverified real-server or device behavior.
5. **Later:** desktop adaptation and tray are separate work, gated on platform-specific build environments and explicit UX design.

## Definition of done per workstream

- Scope and acceptance criteria met, with tests showing intended behavior and failure paths.
- `flutter analyze` and relevant `flutter test` commands pass, or blockers are reported with actual output.
- Platform-specific behavior is tested on that platform or explicitly marked unverified.
- User-facing errors are actionable; accessibility, privacy and credentials are considered.
- Agent hands off file changes, commands run, results, remaining risks, and any required integration decisions.
