# Saathi

A standalone, mobile-first Flutter companion for AI models and agents. Inspired by [Sathi](https://github.com/ss44/sathi.ai), independent of Dank Material Shell, and no longer limited to Hermes. Android first, with shared core logic and Linux/macOS runners.

## What works in this implementation

- Multiple named connections, including separate instances of the same provider.
- OpenAI-compatible, Anthropic and Gemini model discovery/chat adapters; manual model IDs when discovery is unavailable.
- Conversation-specific model/system prompt, local history, new/switch/delete conversations, Markdown responses.
- API keys in platform secure storage, separate from ordinary conversation/settings data.
- Running status, swipe-to-reveal completed activity, immediate long-press copy, safe recoverable errors.
- Native Hermes capability discovery and paginated **read-only** remote session/history browsing.
- Shared-session gateway transport in a separate module; see its authentication/attachment limitations below.
- Startup/resume update checks, visible update availability, manual update settings, verified Android APK download and native installer handoff after consent. No repository or release is assumed.

The Dart core also supports OpenAI/Hermes SSE and usage/grounding metadata. The current mobile chat UI uses completed responses, not streaming. Automated tests use explicit synthetic HTTP/WebSocket/display fixtures; no production provider or user's live session has been used to certify interoperability.

## Session ownership

Direct-model chats send bounded relevant history. Server-owned agent sessions can send only new input plus session identity, reducing mobile upload size—not necessarily model context/token usage.

Browsing history is not live attachment. Hermes REST refuses writes to Desktop/CLI-owned sessions; native gateway attachment needs a trusted authenticated grant and reachable connection. The transport module is not a completed mobile login/tunnel broker and is not wired as one-click attachment in the UI. OpenClaw native gateway pairing/control remains unsupported rather than pretending the old DMS HTTP guesses are an integration. See [gateway contract](docs/GATEWAY_API.md) and [integration notes](docs/INTEGRATION_NOTES.md).

## Develop and test

```sh
flutter pub get
flutter analyze
flutter test
python3 -m unittest discover -s tool -p 'test_*.py' -v
```

On the original development host Flutter is at `/opt/data/tools/flutter/bin`; add it to PATH when needed. If concurrent Flutter processes temporarily contend on shader test assets, serialize builds; scoped pure-Dart tests can use `flutter test --no-test-assets`, but this does not replace final normal-suite validation.

Native builds require the platform toolchain. Android SDK/device tests, Linux GTK/clang/ninja/libsecret build dependencies, and macOS/Xcode/signing are not supplied by Flutter unit tests. Credentials fail closed if secure storage is unavailable. Use HTTPS for a phone-accessible server; the phone's localhost is not your computer. Cleartext is allowed only for loopback development.

## Desktop binary releases

The **Desktop binary releases** Actions workflow builds macOS universal (Intel + Apple Silicon), Windows x64, and Linux x86-64 archives. Run it manually or push a validated weekly tag such as `v2026.46.1`. Versions use ISO year.week.increment; the increment resets each week and the version is embedded in every binary. Builds are published together with `SHA256SUMS` as unsigned previews only after tests and all three native builds pass. Desktop self-installation is deliberately disabled in these packages. See [desktop release instructions](docs/DESKTOP_RELEASES.md) for triggers, signing/runtime caveats and verification limits.

## Updates and release setup

The source repository is `ss44/Saathi-Flutter`. Uploading the included workflows requires token Workflows write permission (or classic `workflow` scope). For the separate Android updater, configure `SAATHI_UPDATE_OWNER=ss44` and `SAATHI_UPDATE_REPO=Saathi-Flutter` at build time and choose a stable/beta channel. Without configuration, update checks make no GitHub requests; configuring the repository alone does not create a signed release.

For standalone Android distribution, provide production signing through ignored `android/key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`). No keys are included, and release builds must not silently use debug signing. Keep the signing identity stable across updates. Generate release metadata using `tool/generate_update_manifest.py` only after checking actual APK signing.

Saathi validates release identity, version/build/channel, URLs, artifact size and SHA-256 before handing a private-cache APK to Android. Native code checks package/version/signers; Android still requires installation consent. **Installer opened does not mean update installed.** This flow still needs a signed first release and physical-device upgrade testing.

Desktop currently offers a manual release-page action, not Hermes-style automatic replacement/relaunch. Play builds require a separate permission-free manifest and Play update integration; setting a Dart flag alone is insufficient. Full format, trust model, commands and limits: [Updates](docs/UPDATES.md).

## Design and remaining work

[Design decisions](docs/UI_DECISIONS.md) explains what carries over and what does not. [Port audit](docs/PORT_AUDIT.md) records source provenance and coverage. [Product specification](docs/SPEC.md) defines the independent-app direction.

Not complete: connection editing/removal, Android share/image intake, smart-context bucket negotiation, UI streaming/cancel UX, native OpenClaw, mobile gateway sign-in/bootstrap, desktop tray/installer packaging, iOS runner. App IDs currently use `io.github.ss44.saathi`; choose the final stable identifiers before publishing.

`docs/previews/saathi-*.png` are Flutter test renders, including explicitly synthetic conversation previews—not device screenshots or real model answers. Older Iris demo renders remain as historical design artifacts.
