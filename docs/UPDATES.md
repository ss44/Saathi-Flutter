# Saathi updates — integration contract

## Public API (implementation in `lib/updates/saathi_updates.dart`)

Dependencies: Flutter SDK, `http`, `crypto`, `url_launcher`; no additional packages or secrets.

```dart
final updates = SaathiUpdateController(
  service: SaathiUpdateService(
    config: UpdateConfig.fromEnvironment(),
    installed: UpdateVersion.parse('0.1.0', 1), // MUST match installed package
  ),
);
updates.start(); // startup check + resume observer; call once, dispose with owner
// Listen via ListenableBuilder / addListener:
// updates.status, updates.offer, updates.error, updates.progress
await updates.check(force: true); // user-requested check; background is throttled
// Only after an explicit confirmation dialog:
await updates.openReleasePage(userConsented: true); // practical browser fallback
// Android only, AFTER native bridge wired and explicit consent:
await updates.installAndroid(userConsented: true);
```

`UpdateStatus`: disabled, idle, checking, upToDate, available, downloading,
handedOff, error. `handedOff` means only installer/browser opened, NOT installed.
`UpdateOffer`: version, channel, platform, releaseUrl, assetUrl, assetName,
size, sha256. `UpdateVersion.parse(name, build)` compares semantic versions and
requires a strictly greater Android build number to offer an update.

Configuration (`--dart-define`): `SAATHI_UPDATE_OWNER`, `SAATHI_UPDATE_REPO`,
`SAATHI_UPDATE_CHANNEL=stable|beta` (default stable),
`SAATHI_DISTRIBUTION=standalone|play|disabled` (default standalone).
Unconfigured/invalid repository or channel, play and disabled distributions make
NO GitHub requests. No repository is assumed. Supply the actual installed version
from package metadata or verified build constants, not latest remote metadata.

## Android bridge contract (implemented by Android platform owner)

Channel `saathi/updates`:

1. `getCacheDirectory()` returns the absolute private `cacheDir/updates` directory.
   It already includes `updates`; Dart does not append another `updates` segment.
2. Dart writes bounded, SHA-256-verified bytes to a `.part` file there, flushes and
   independently hashes the disk file, then atomically renames to
   `saathi-BUILD-SHA256.apk`. Filenames never come from remote metadata.
3. `installApk({'path': absolutePath})` returns null when installer UI launches.
   This means handoff, **not successful installation**. A missing bridge is an error.
4. `PlatformException(code: 'install_permission_required')` means Android source
   permission settings opened. Dart shows a clear instruction to allow the source
   and explicitly tap Install again; it does not report success or auto-retry.

Native code validates canonical direct-child `.apk` paths inside its cache scope,
APK application ID, strictly newer versionCode, and identical signing certificate
set. It grants read-only FileProvider access, launches Android's installer and lets
Android request consent. No shell commands or downloaded Dart/native code loading.
Failed handoffs remove Dart's temporary/candidate APK. Successful handoffs retain
the file because the installer may still need it. Cache reclamation is OS-managed;
a future cleanup task must not delete an APK still in use by the installer.

The client caps APK size at 150 MiB (native bridge independently caps 512 MiB).
Downloads are buffered in memory; streaming-to-disk is a future optimization. No
bytes travel over MethodChannel and no `path_provider` dependency is needed.
Only a standalone flavor may declare REQUEST_INSTALL_PACKAGES. A Play manifest
override MUST remove that permission **and** compile with
`SAATHI_DISTRIBUTION=play`; Dart flags alone do not remove manifest permissions.
Play updating is not implemented here: use Google Play's update APIs for that
separate distribution. Browser fallback needs no installer permission and does
not offer a verified-download guarantee for what the browser downloads.

## Release format and publishing

The release tag is exactly `vSEMVER+BUILD`, e.g. `v1.1.0+2` (illustration, not an
existing release). Stable tags must use a non-prerelease semver and GitHub
`prerelease: false`; beta tags may be prereleases with `prerelease: true` or final
versions marked false. Channels are explicit manifests, not inferred from a tag.
A beta client only reads `saathi-update-beta.json`; promote a release by deliberately
publishing a stable manifest on a final-version release. Never republish an older
Android build number. Both semver and versionCode must advance; same semver with a
higher build is supported. Semver build metadata (`+...`) belongs in the separate
integer `build` field and is not accepted inside `version`.

A published GitHub release must contain a universal, **production-signed APK**
and `saathi-update-stable.json` (or beta). The APK must support the target device;
split APK sets and AABs are not single-APK installer inputs. Metadata schema:

```json
{
  "schema": 1,
  "version": "1.1.0",
  "build": 2,
  "channel": "stable",
  "platform": "android",
  "asset": {
    "name": "saathi.apk",
    "size": 12345,
    "sha256": "64 lowercase hexadecimal characters, generated from actual APK",
    "url": "https://github.com/OWNER/REPO/releases/download/v1.1.0%2B2/saathi.apk"
  }
}
```

This example is schematic; its checksum is intentionally not valid. Generate real
metadata rather than copying it:

```sh
# Configure production signing first. Never use a debug signing identity.
flutter build apk --release --build-name 1.1.0 --build-number 2 \
  --dart-define=SAATHI_UPDATE_OWNER=YOUR_OWNER \
  --dart-define=SAATHI_UPDATE_REPO=YOUR_REPO \
  --dart-define=SAATHI_DISTRIBUTION=standalone
# Use Android SDK build-tools/apksigner, and compare certificate digest to the
# established, securely recorded production signer. Unsigned APK MUST fail here.
apksigner verify --verbose --print-certs build/app/outputs/flutter-apk/app-release.apk
python3 tool/generate_update_manifest.py \
  --owner YOUR_OWNER --repo YOUR_REPO --version 1.1.0 --build 2 \
  --channel stable --apk build/app/outputs/flutter-apk/app-release.apk \
  --output build/saathi-update-stable.json
# Create a draft tag v1.1.0+2, upload BOTH assets, verify metadata and APK signing,
# then publish the draft atomically. Do not edit published release assets.
```

The Python generator hashes and bounds the APK but **does not sign or verify APK
signing**. Tests deliberately use non-installable fixture bytes; they prove
manifest behavior, not production signing. `android/key.properties` production
signing configuration is owned by the Android build. With no release key supplied,
a build is not a distributable update. Back up the production signing key securely;
losing it breaks upgrades. Same app ID and signing identity are required for in-place
updates. Google Play App Signing may use a different app signing certificate than
the upload key; don't expect arbitrary sideload APKs to replace Play installations.
This bridge requires an identical signer set; signing-key rotation needs an explicit
native signing-lineage design and is not supported by this implementation.

No release workflow uploads unsigned APKs or assumes a repository. The manifest-check workflow runs generator unit tests; `verify.yml` additionally runs Flutter formatting, analysis and tests. Hosted execution is not verified until the user creates/pushes the repository. Real release automation requires an actual repo,
protected release environment, least-privilege release token, secure signing-key
provisioning, signer-digest verification and a production signing policy. Do not
commit keys/passwords or embed GitHub tokens in the application.

## Trust boundary and limitations

- Automated startup/resume checks are throttled to six hours per app process;
  manual checks bypass the timer, but concurrent checks/downloads are coalesced
  or ignored. Errors do not crash startup. Consent is required before downloading
  an APK or opening an external browser. No silent installer or background daemon.
- Public GitHub API only; no private-repository tokens. Up to 30 recent releases
  and a 1 MiB metadata response are considered. The highest eligible version is
  selected, not API order. Keep a current manifest among those releases. API rate
  limits/network errors are reported; no insecure retry or metadata fallback.
- Repository release pages/asset URLs must match the configured owner/repo/tag.
  HTTPS only; no URL user-info, fragments, custom ports, query-bearing source
  URLs, HTTP downgrade or cross-repository links. Downloads allow at most three
  redirects to GitHub's exact release CDN hosts over HTTPS. Signed CDN query
  parameters are neither logged nor exposed to the user.
- Manifest maximum 64 KiB; APK maximum 150 MiB. Advertised GitHub size must equal
  manifest size, exact downloaded size and SHA-256 must match, and GitHub's asset
  digest (when supplied) must also agree. Per-response idle timeout is 30 seconds,
  with a five-minute transfer bound. Metadata/manifest input is untrusted.
- HTTPS and SHA-256 detect transport/storage corruption, not a malicious repository
  owner: the checksum and APK come from the same release. This is **not a signed
  update-metadata protocol** (TUF/Ed25519 are not implemented). Android's installed
  signing identity and native package/version checks are the execution trust
  anchor. Restrict repo publication, enable account MFA, protect release tags and
  prefer immutable releases. Repository compromise can still cause denial of
  service, bogus release notes or replay of signed-but-vulnerable newer builds.
- Native file/package/signature validation is defense in depth, not optional.
  Dart checks do not replace Android's installer checks. File cache deletion is
  best effort and successful handoff does not imply the user accepted installation.
- Desktop: this module can offer a consentful HTTPS release page, but it does not
  replace app bundles, elevate privileges, execute installers or implement a
  Hermes-like desktop updater. Default manifest platform is Android; a desktop UI
  should label this action **Open releases**, not **Install desktop update**.
  Per-desktop signed/notarized/package-manager updates are separate future work.
- No actual repository or signed release has been supplied. Production discovery,
  OS permission UX, physical-device install and upgrade preservation require those
  inputs and device testing. Local fixture tests exercise download, corruption
  rejection, private-cache write and native channel handoff, not OS installation.

## Official references used for the design

- Android Play in-app updates: https://developer.android.com/guide/playcore/in-app-updates
  (Google Play update flow, including user-facing flexible/immediate flows).
- Android source-install trust: https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls()
  (per-source approval from Android O and REQUEST_INSTALL_PACKAGES).
- Android secure file sharing: https://developer.android.com/training/secure-file-sharing/share-file
  (FileProvider content URI and temporary read permission rather than file://).
- Android app signing: https://developer.android.com/studio/publish/app-signing
  (installed app signing identity and release signing).
- Flutter Android release/signing: https://docs.flutter.dev/deployment/android
- Flutter platform channels: https://docs.flutter.dev/platform-integration/platform-channels
- Google Play sensitive permissions policy: https://support.google.com/googleplay/android-developer/answer/16558241
  (REQUEST_INSTALL_PACKAGES must not be used for Play app self-updates).
- Google Play device/network abuse: https://support.google.com/googleplay/android-developer/answer/16559646
  (Play apps must update through Play, not external self-replacement).
- GitHub release/asset REST metadata: https://docs.github.com/en/rest/releases/releases
  and https://docs.github.com/en/rest/releases/assets

## Verification

```sh
flutter test test/updates
flutter analyze lib/updates test/updates
python3 -m unittest discover -s tool -p 'test_*.py' -v
dart format --output=none --set-exit-if-changed lib/updates test/updates
```
