# Iris — Product Specification (working outline)

## 1. Product summary
A calm, message-first Flutter client for interacting with a remote Hermes Agent instance. The experience should feel familiar like a messaging app rather than an agent control panel.

## 2. Goals
- Make starting and continuing a conversation obvious.
- Keep session history accessible without overwhelming the chat.
- Accept text and image shares from Android apps into a conversation, with a clear review-before-send step.
- Let a user configure the Hermes server URL and authentication.
- Start on Android while preserving a path to Linux/macOS desktop and tray use.

## 3. Non-goals (initial milestone)
- Reimplementing Hermes Agent features or administration surfaces.
- Full parity with every tool, channel, or desktop feature.
- Production-ready cross-platform tray integration.

## 4. Primary user flow
1. Configure server URL and auth.
2. Validate/save connection settings.
3. Open or create a conversation.
4. Send messages and view responses.
5. Return to prior sessions.

## 5. UX principles
- Conversation is the home screen; keep navigation and controls quiet.
- Make the message text itself clean, highly legible, and comfortably large by default; respect system text scaling.
- Distinguish user and assistant messages clearly without heavy visual framing.
- Keep thinking and tool activity available, but grouped and visually secondary; let users expand details on demand.
- Session list is secondary and easy to reach.
- Connection/setup states are understandable and recoverable.
- Accessible touch targets, readable contrast, and responsive layouts.

## 6. Initial scaffold milestone
A runnable Flutter shell with a conversation-first screen, session navigation, and a connection/settings form for base URL plus an auth credential placeholder. Until API compatibility is verified, chat behavior may be local/mock and must be labeled as such.

## 7. Integration questions / decisions required
- Target the official Hermes API server; discover capabilities and confirm behavior against the actual deployed version. See `INTEGRATION_NOTES.md`.
- Confirm server address, supported authentication, streaming, session APIs and session-image payload for the target installation.
- Credential storage and certificate/TLS expectations.
- Whether an existing installation exposes a stable client API; verify against current docs/source before coding the adapter.

## 8. Data and security
- Store session history locally only if/when agreed; define retention and deletion.
- Never log or persist secrets in plaintext. Use platform secure storage for credentials.
- Require HTTPS for non-local remote connections unless a deliberate development exception is made.

## 9. Platform roadmap
- Phase 1: Android UI and connection setup.
- Phase 2: Remote chat/session integration and robust error handling.
- Phase 3: Linux/macOS desktop adaptation and tray behavior.

## 10. Acceptance criteria (initial)
- Flutter project structure includes Android, Linux and macOS runners; each platform run/build requires its own host toolchain.
- Chat-first shell and settings entry point are defined.
- URL/auth setup can be represented without exposing credentials.
- Open API/auth decisions are tracked rather than guessed.
