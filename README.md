# Saathi

A lightweight, conversation-first Flutter client for AI models and agents. Hermes is the primary native-agent compatibility target; the broader direction follows [Sathi](https://github.com/ss44/sathi.ai)'s multi-agent feel. Direct models and native agent clients use separate adapters, with behavior driven by each connection's verified features. Android first, independent of Dank Material Shell. See the [product direction](docs/PRODUCT_DIRECTION.md) and [contributor guardrails](.agents/AGENTS.md).

## What works in this implementation

- Multiple named connections, including separate instances of the same provider, with editing and explicit deletion.
- OpenAI-compatible, Anthropic and Gemini model discovery/chat adapters; manual model IDs when discovery is unavailable.
- Conversation-specific model/system prompt, local history, new/switch/delete conversations, Markdown responses.
- API keys in platform secure storage, separate from ordinary conversation/settings data.
- Running status, swipe-to-reveal completed activity, immediate long-press copy, safe recoverable errors.
- Native Hermes capability discovery and paginated **read-only** remote session/history browsing.
- Explicit trusted-host invitation import and canonical Hermes Desktop/CLI attachment, separate from REST history browsing; see deployment limitations below.
- Local conversation rename/archive, shared personas where supported, visibility-based unread replies and reported usage.
- Startup/resume update checks, visible update availability, manual update settings, verified Android APK download and native installer handoff after consent. No repository or release is assumed.

The Dart core also supports OpenAI/Hermes SSE and usage/grounding metadata. Native Hermes Runs and canonical conversations show streamed visible text and reconcile authoritative completion; direct-model chat UI still uses completed responses. Automated tests use explicit synthetic HTTP/WebSocket/display fixtures. Separate opt-in probes exercise official Hermes machinery with non-inferencing execution stubs, not a production provider or user's live session. See [Hermes acceptance evidence](docs/HERMES_DELIVERY_ACCEPTANCE.md) for its scope and remaining deployment/device gates.

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

## Desktop and Android binary releases

The **Desktop and Android binary releases** Actions workflow builds macOS universal (Intel + Apple Silicon), Windows x64, Linux x86-64, and a release-signed universal Android APK. It runs daily at **09:00 UTC**; use **Run workflow** for an on-demand testing build. Branch and tag pushes do not trigger binary releases. Unchanged tracked trees since the latest published weekly release (including beta prereleases) skip the entire release. Changed trees reserve a hidden draft pinned to one full commit SHA before verification/builds. Versions use ISO year.week.increment; Git tags and drafts reserve increments. Flutter build flags apply the version bump without committing pubspec changes. All four native builds and tests must pass before publishing the binaries, beta update manifest, and checksums together. Desktop artifacts remain unsigned previews with self-installation disabled. Android embeds this repository's beta update configuration and uses a persistent standalone signing key. See [release instructions](docs/DESKTOP_RELEASES.md) and [private signing setup](docs/ANDROID_SIGNING.md). The Android Actions artifact can also be downloaded as soon as its build finishes.

## Updates and release setup

The source repository is `ss44/Saathi-Flutter`. Uploading the included workflows requires token Workflows write permission (or classic `workflow` scope). For the separate Android updater, configure `SAATHI_UPDATE_OWNER=ss44` and `SAATHI_UPDATE_REPO=Saathi-Flutter` at build time and choose a stable/beta channel. Without configuration, update checks make no GitHub requests; configuring the repository alone does not create a signed release.

For standalone Android distribution, supply the five Actions secrets in [signing setup](docs/ANDROID_SIGNING.md), or use ignored local `android/key.properties` (`storeFile`, `storeType=PKCS12`, `storePassword`, `keyAlias`, `keyPassword`). No keys or passwords are included in source; CI fails rather than using unsigned/debug fallback. Keep the signing identity stable across updates. Generate release metadata only after verifying actual APK signing. Android uses the deterministic `YYYYWWIIII` internal versionCode, e.g. `2026460001`, while the visible version remains `2026.46.1`.

Saathi validates release identity, version/build/channel, URLs, artifact size and SHA-256 before handing a private-cache APK to Android. Native code checks package/version/signers; Android still requires installation consent. **Installer opened does not mean update installed.** Publishing a signed binary does not establish physical-device upgrade acceptance.

Desktop currently offers a manual release-page action, not Hermes-style automatic replacement/relaunch. Play builds require a separate permission-free manifest and Play update integration; setting a Dart flag alone is insufficient. Full format, trust model, commands and limits: [Updates](docs/UPDATES.md).

## Design and remaining work

[Design decisions](docs/UI_DECISIONS.md) explains what carries over and what does not. [Port audit](docs/PORT_AUDIT.md) records source provenance and coverage. [Product specification](docs/SPEC.md) defines the independent-app direction.

Not complete: Android share/image intake, smart-context bucket negotiation, direct-model UI streaming/cancel UX, native OpenClaw, mobile gateway sign-in/tunnel provisioning, desktop tray/installer packaging, iOS runner. App IDs use `io.github.ss44.saathi`; preserve application and signing identity for compatible upgrades.

`docs/previews/saathi-*.png` are Flutter test renders, including explicitly synthetic conversation previews—not device screenshots or real model answers. Older Iris demo renders remain as historical design artifacts.
