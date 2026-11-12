# Saathi — product specification

## Identity and purpose
A standalone, mobile-first Flutter home for AI conversations, inspired by the user's Sathi DMS client. It is not tied to DMS, Hermes, or a single model vendor. Working name: **Saathi**. Android is first; Linux/macOS share the core and may eventually replace Sathi on desktop.

## Core experience
- Open into a calm conversation screen, not an agent administration dashboard.
- Configure multiple named instances, including multiple connections of the same provider type.
- Direct models: OpenAI-compatible servers, Anthropic, Gemini, using provider-specific translation behind one interface.
- Agent backends: capability-aware adapters, not a false claim of universal parity.
- Discover/select models, set a system prompt, render markdown, retain usage metadata where supplied.
- Local session creation/switching/history with credentials stored separately in platform secure storage.
- New conversations start empty; no fake response is presented as a live model answer.
- Observable activity appears during work and is tucked away afterward; swipe a response to reveal activity, long-press to copy text. Errors and approval requests stay explicit.

## Session ownership and network use
A direct-model chat normally uploads its relevant conversation context on each request. A server-owned agent session sends only new input and remote identity, letting the server retain authoritative state. Avoid sending both a full copied transcript and a session ID when the server already owns history.

Remote browsing, reading history, continuing a server-owned API conversation, and attaching to another client's live session are distinct capabilities. Hermes documents REST listing/history and API-session continuation; the ordinary REST API rejects writes to sessions owned by Desktop/CLI. Live shared attachment requires its gateway protocol. OpenClaw similarly needs a verified native gateway adapter for its session features. Do not substitute guessed HTTP endpoints or label imported history as live attachment.

## Data/security
- API credentials: platform secure storage; never ordinary preferences or session JSON.
- Chat history: local application storage, not advertised as end-to-end encrypted. User-controlled deletion and clear scope.
- Bind conversations to their connection; no silent cross-provider transcript disclosure.
- HTTPS by default; local development exceptions must be narrow and intentional. Never disable TLS checks.
- No actual user keys/prompts are used in automated tests.
- Do not automatically retry a potentially admitted agent turn without reliable idempotency/outcome information.

## Updates
- Automated release checking at launch/resume, plus a manual check.
- Release source is build-configured after the user creates the GitHub repo. No guessed organization/repo or embedded GitHub credential.
- Validate version/build/channel and trusted HTTPS download URLs; verify artifact size/checksum before any native-install path.
- Android installation requires OS/user consent and consistent release signing. Google Play builds must use the store's supported update mechanism rather than a sideload installer.
- Linux/macOS replacement/relaunch needs a platform-specific signed/package-aware installer. Opening a verified release page is a fallback, not a silent auto-install.
- Document clearly what is implemented, tested, and blocked on first signed release.

## Build on from Sathi
Keep multi-provider instances, model discovery, provider-neutral messages, system prompts, useful usage/status metadata, and conversation continuity. Reimplement in Dart; do not embed QML/JS runtime state.

Leave DMS widget registration, shell theme bindings, shell-global singleton state, panel pin/resize behavior, plugin-service persistence, stale price tables, and guessed agent endpoints behind. Smart context bucket routing is a separate optimization: it must not silently add extra paid model calls or negotiate context for a server-owned agent session.

## Later milestones
- Real deployed-provider and gateway interoperability tests.
- Native shared-session gateway attachment/live stream reconciliation.
- Android share-to-draft (text/images) and image payload support.
- Optional smart context routing and opt-in price estimation based on maintained price data.
- Desktop navigation/keyboard/tray and production update install flows.
- iOS runner/store distribution is not part of the existing scaffold; macOS packaging requires macOS/Xcode.

## Verification standard
Tests against a controlled local HTTP fixture verify request translation and session semantics, not live vendor compatibility. Widget tests verify mobile layouts and controls. Native Android/desktop builds and secure-storage/install behavior require their own toolchains/devices. Do not conflate these levels.
