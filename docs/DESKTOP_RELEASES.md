# Desktop binary releases

Workflow: `.github/workflows/release-desktop.yml` → **Desktop binary releases** in GitHub Actions.

## Trigger

- Use **Run workflow** on the intended source branch. UTC time selects the ISO week-year/week; the highest existing increment for that week is increased by one (starting at 1). All tags are fetched before allocation.
- Or push an exact tag such as `v2026.46.1` (`vYEAR.WEEK.INCREMENT`). Valid explicit values are preserved.
- Ordinary branch pushes do not publish releases. Invalid ISO weeks, leading-zero week/increment values, shell-like tags and increments/internal builds outside 1–65535 fail before compilation. These bounds keep Windows VERSIONINFO components valid.

Version example: **`2026.46.1`** → `2026.46.2` → next week `2026.47.1`. The release tag is `v2026.46.1`; there is no `+BUILD` in release names or archive filenames. Flutter receives that three-part version plus a separate internal `github.run_number` build identifier. ISO week-year handles New Year correctly (January 1 can belong to the previous ISO year).

All desktop release runs share one concurrency group so two manual runs cannot allocate the same weekly increment simultaneously. Do not delete version tags: they are the allocation ledger. A fresh manual metadata run chooses the next available increment; rerunning only failed jobs retains prior outputs. Existing releases/drafts are never overwritten; remove an incomplete draft deliberately before retrying its reserved version. Explicit tags should advance the weekly counter, not reuse lower increments.

## Jobs and output

1. Validate/generate ISO year.week.increment metadata using `tool/desktop_release.py`.
2. Run formatting, analysis, Flutter tests and Python tooling tests.
3. Build in native hosted runners:
   - Ubuntu 22.04 → Linux x86-64 complete bundle (`.tar.gz`), preserving executable modes and symlinks.
   - Windows Server 2022 → Windows x64 complete bundle (`.zip`), including all runtime DLLs/assets.
   - macOS 15 Intel → universal `.app` (`.zip` via `ditto`, preserving framework links). `lipo` asserts both Intel and Apple Silicon slices in the app, Dart AOT framework and Flutter engine.
4. Only after all builds pass, collect exactly three archives and create `SHA256SUMS` from the real files.
5. Create an **unsigned prerelease draft**, upload all artifacts, confirm four assets exist, then publish. A failure before publishing leaves a draft for inspection, not a misleading partial public release. Existing releases—including incomplete drafts—are not overwritten automatically.

Artifact names: `Saathi-VERSION-linux-x64.tar.gz`, `Saathi-VERSION-windows-x64.zip`, `Saathi-VERSION-macos-universal.zip`, plus `SHA256SUMS`.

## Signing and runtime caveats

No code-signing identities are available. These are explicitly unsigned previews, not production-certified installers. The workflow does not claim Apple notarization, Windows Authenticode, package-manager integration or automatic desktop replacement. Add platform signing/notarization as a separate protected release stage before promoting builds to stable.

The standalone macOS client uses the plugin's documented legacy Keychain option (`MacOsOptions(usesDataProtectionKeychain: false)`) and does not request Keychain Sharing. Saathi does not share keys with another application; this avoids an unnecessary machine-specific provisioning profile. Credentials still live in the macOS Keychain, not plaintext preferences. The source/option regression is tested; actual OS behavior still needs a Mac.

Linux secure storage requires libsecret and a running Secret Service. Windows may need the VC++ x64 runtime. Builds are portable directories, not single executables. See the release notes for end-user requirements. Flutter does not provide a supported 32-bit Linux x86 target; this workflow explicitly builds `linux-x64`.

The desktop builds use `SAATHI_DISTRIBUTION=disabled`; they do not consume Android update manifests or promise an unsupported desktop self-installer. The Android release/update pipeline remains separate.

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
