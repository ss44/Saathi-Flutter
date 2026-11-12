# Saathi — delivery ownership

## Current coordinated work
The user authorized rebranding the existing Flutter prototype and reimplementing useful Sathi behavior for a standalone mobile-first multi-provider app. The user will create the GitHub repository; no remote is configured or pushed by this work.

One integration owner controls `pubspec.*`, platform runners, project identity, root guidance and final validation. Parallel implementers have disjoint paths in this working tree (an explicit exception to the old worktree plan because the prototype contains valuable uncommitted work):

| Track | Exclusive paths | Responsibility |
|---|---|---|
| Core | `lib/core/`, `test/core/`, `docs/CORE_API.md`, `docs/PORT_AUDIT.md` | Provider translations, capability discovery, sessions, source audit |
| UI/data | `lib/main.dart`, `lib/ui/`, `lib/storage/`, UI/storage tests, `docs/UI_DECISIONS.md` | Mobile experience, secure credential separation, conversation persistence |
| Updates | `lib/updates/`, `test/updates/`, `tool/`, `.github/workflows/`, `docs/UPDATES.md` | Release checking, validation, release preparation |
| Integration | All shared/platform/root files; integration tests | Rebrand, assemble, review, full verification |

Do not overwrite another track. Public contracts live in the docs above. Use test-first slices and deterministic local HTTP fixtures; no live credentials or paid test prompts. Do not claim live session attachment from mere history import. After parallel work ends, integration may edit any path to fix defects and wire the final app.

## Explicit follow-ups
- User-created remote and release identity/signing keys.
- Native Android build/device secure-storage and installer checks.
- Gateway-based attachment to sessions open in another client.
- Share-sheet/image input; desktop-specific navigation/tray/installer packaging.
- Opt-in smart-context bucket routing, if useful after server-owned sessions are supported.

## Completion bar
`dart format`, `flutter analyze`, complete `flutter test`, local end-to-end transport tests and release-tool tests. Platform build limitations and live-server validation gaps must be reported, never hidden behind passing unit tests.
