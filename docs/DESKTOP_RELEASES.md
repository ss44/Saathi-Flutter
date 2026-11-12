# Desktop binary releases

Workflow: `.github/workflows/release-desktop.yml` → **Desktop binary releases** in GitHub Actions.

## Trigger

- Use **Run workflow** on the intended source branch. This generates today's UTC date plus `github.run_number`.
- Or push a tag exactly shaped `vYYYY.M.D+BUILD`, e.g. `v2026.11.12+42`. The tag's date/build are used unchanged after validation.
- Ordinary branch pushes do not publish releases. Invalid dates, leading-zero month/day/build values, shell-like tag input and builds outside 1–65535 fail before compilation. The build-number ceiling keeps Windows VERSIONINFO components valid.

Version example: `2026.11.12+42`. Flutter receives build name `2026.11.12` and build number `42`; release tag is `v2026.11.12+42`. Rerunning a successful version deliberately fails instead of replacing published binaries; start a new workflow run for a new version. Explicit tags must use a higher build number than earlier published versions if chronological version ordering matters. Do not mix low manual counters with a higher workflow counter.

## Jobs and output

1. Validate/generate version metadata using `tool/desktop_release.py`.
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
