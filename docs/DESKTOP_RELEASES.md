# Desktop and Android binary releases

Workflow: `.github/workflows/release-desktop.yml` → **Desktop and Android binary releases** in GitHub Actions. For Android signing setup and private backups, see `ANDROID_SIGNING.md`.

## Trigger

- Automatic builds run **weekly on Mondays at 09:00 UTC** from the default branch. GitHub may delay scheduled execution; this is not a guaranteed wall-clock deadline.
- Use **Run workflow** on the intended source branch for an on-demand testing build. UTC time selects the ISO week-year/week; the highest existing increment for that week is increased by one (starting at 1). All tags are fetched before allocation.
- Branch pushes (including `main`) and tag pushes do not trigger binary releases. PR/main verification workflows remain separate and do not publish binaries.
- Invalid ISO weeks, leading-zero values and shell-like tags fail before compilation. Combined release increments are 1–9999, desktop internal builds are 1–65535, and Android versionCode must be at most 2100000000.

Version example: **`2026.46.1`** → `2026.46.2` → next week `2026.47.1`. The release tag is `v2026.46.1`; there is no `+BUILD` in release names or archive filenames. Flutter receives that three-part version plus a separate internal `github.run_number` build identifier. ISO week-year handles New Year correctly (January 1 can belong to the previous ISO year).

All desktop release runs share one concurrency group so two manual runs cannot allocate the same weekly increment simultaneously. Do not delete version tags: they are the allocation ledger. A fresh manual metadata run chooses the next available increment; rerunning only failed jobs retains prior outputs. Existing releases/drafts are never overwritten; remove an incomplete draft deliberately before retrying its reserved version. Explicit tags should advance the weekly counter, not reuse lower increments.

## Jobs and output

1. Validate/generate ISO year.week.increment metadata using `tool/desktop_release.py`.
2. Run formatting, analysis, Flutter tests and Python tooling tests.
3. Build in native hosted runners:
   - Ubuntu 22.04 → Linux x86-64 complete bundle (`.tar.gz`), preserving executable modes and symlinks.
   - Windows Server 2022 → Windows x64 complete bundle (`.zip`), including all runtime DLLs/assets.
   - macOS 15 Intel → universal `.app` (`.zip` via `ditto`, preserving framework links). `lipo` asserts both Intel and Apple Silicon slices in the app, Dart AOT framework and Flutter engine.
   - Ubuntu 22.04 + Java 17 → universal release-signed Android APK with beta updates enabled. Android SDK tools verify its signature, configured signer, application ID, versionName, and versionCode before upload. Missing credentials fail the job; there is no unsigned/debug fallback. Temporary signing files are removed even after failures.
4. Only after all four native builds pass, collect the three desktop archives, APK and beta manifest; create `SHA256SUMS` from the real files.
5. Create a **prerelease draft**, upload all six assets including checksums, read back exact names/sizes and available digests, then publish. A failure before publishing leaves a draft for inspection, not a misleading partial public release. Existing releases—including incomplete drafts—are not overwritten automatically. The APK/manifest Actions artifact `binary-android` is available as soon as its own build finishes, even if another platform later fails.

Artifact names: `Saathi-VERSION-linux-x64.tar.gz`, `Saathi-VERSION-windows-x64.zip`, `Saathi-VERSION-macos-universal.zip`, `Saathi-VERSION-android.apk`, `saathi-update-beta.json`, and `SHA256SUMS`.

## Signing and runtime caveats

Desktop code-signing identities are not configured. Desktop artifacts remain unsigned previews; Android uses the persistent standalone PKCS12 signing identity stored in Actions secrets. The workflow does not claim Apple notarization, Windows Authenticode, Google Play enrollment, package-manager integration or automatic desktop replacement.

The standalone macOS client uses the plugin's documented legacy Keychain option (`MacOsOptions(usesDataProtectionKeychain: false)`) and does not request Keychain Sharing. Saathi does not share keys with another application; this avoids an unnecessary machine-specific provisioning profile. Credentials still live in the macOS Keychain, not plaintext preferences. The source/option regression is tested; actual OS behavior still needs a Mac.

Linux secure storage requires libsecret and a running Secret Service. Windows may need the VC++ x64 runtime. Builds are portable directories, not single executables. See the release notes for end-user requirements. Flutter does not provide a supported 32-bit Linux x86 target; this workflow explicitly builds `linux-x64`.

The desktop builds use `SAATHI_DISTRIBUTION=disabled`; they do not consume Android update manifests or promise an unsupported desktop self-installer. Android embeds the repository owner/name and beta update channel. Its internal code is deterministic `YYYYWWIIII` (e.g. `2026460001` for `2026.46.1`), not the desktop run number. The GitHub prerelease flag may be true for a final weekly SemVer on the beta channel; stable still rejects prereleases. Publishing does not prove a real device accepted an upgrade.

## Repository permissions

Uploading this workflow requires the developer's token to have **Workflows write** (or classic `workflow` scope), in addition to repository Contents write. At runtime build/verification jobs have read-only repository permission; only the publish job gets `contents: write`. Checkout does not persist Git credentials. Actions are pinned to resolved commit hashes. No developer PAT, signing key, or model credential is embedded in binaries.

## Local validation and evidence

```sh
python3 -m unittest discover -s tool -p 'test_*.py' -v
flutter test test/platform/desktop_release_test.dart
```

Tooling tests use explicitly synthetic bundle bytes to prove archive completeness, executable/symlink preservation, metadata validation and checksums. They are **not native build evidence**. The macOS/Windows/Linux matrix must actually run successfully in GitHub Actions before calling the binary release verified.

Primary references:
- Flutter platform support: https://docs.flutter.dev/reference/supported-platforms
- Windows packaging: https://docs.flutter.dev/deployment/windows
- macOS packaging: https://docs.flutter.dev/deployment/macos
- Linux packaging: https://docs.flutter.dev/deployment/linux
- Hosted runner labels: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Secure storage plugin macOS guidance: https://pub.dev/packages/flutter_secure_storage_darwin
