# Android signing and private backup

Standalone APKs use a persistent release-signing identity, not Android's debug key. The application ID is `io.github.ss44.saathi`. Keep the **same key** for every upgrade to an installed standalone app.

## Existing identity: restore, do not regenerate

The signing backup is a private ZIP containing an encrypted PKCS12 keystore **and its passwords**. Store the whole ZIP as a private Bitwarden attachment/secure note; never commit it, attach it to an issue, upload it as a release asset, or paste its contents into chat.

The backup contains:

- `saathi-release.p12`: RSA-4096 private key and self-signed certificate, PKCS12 format.
- `signing-credentials.txt`: alias, shared keystore/key password, public certificate fingerprint.
- `keystore-password.txt`: password-file input for OpenSSL.
- `github-secrets.json`: five exact GitHub Actions secret values.
- `certificate.pem`: public certificate only.

A self-signed certificate is normal for standalone APK signing. This config does not enroll the app in Google Play or set up Play App Signing. Keep a separate offline/vault copy: losing this key means existing installs cannot accept an APK signed with a replacement key.

## Only for a new identity

Run this **only if no signing identity has already been created or shipped**:

```sh
python3 tool/generate_android_signing.py --output "$HOME/.local/share/saathi/android-signing"
```

Requires OpenSSL. The generator refuses to write inside the source repository or overwrite any existing output directory. It verifies the real PKCS12 password/MAC and backup ZIP, uses owner-only file permissions, and does not print credentials. It removes its intermediate encrypted private-key file. Store the resulting backup in a vault before releasing an APK.

## GitHub Actions

Set the five repository Actions secrets from `github-secrets.json`:

| Secret | Purpose |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 of the entire binary `.p12` file |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | `saathi-release` for the generated identity |
| `ANDROID_KEY_PASSWORD` | Key password; generated PKCS12 uses the store password |
| `ANDROID_SIGNING_CERT_SHA256` | Lowercase SHA-256 of the DER signing certificate, without colons |

Use repository **Settings → Secrets and variables → Actions**, or an appropriately scoped encrypted secrets API. A fine-grained PAT needs repository **Secrets: Read and write** to provision them; **Actions: Read and write** supports manual workflow dispatch. Source/workflow write access alone does not grant either. Never put secret values into workflow inputs or committed YAML.

The release job must fail if credentials are absent; it must not fall back to debug signing. Temporary CI signing files must not enter the release artifact upload.

## Local release builds

Restore the existing `.p12` outside the source tree. Create ignored `android/key.properties` locally with owner-only permissions:

```properties
storeFile=/absolute/private/path/saathi-release.p12
storeType=PKCS12
storePassword=YOUR_EXISTING_STORE_PASSWORD
keyAlias=saathi-release
keyPassword=YOUR_EXISTING_KEY_PASSWORD
```

Those values are placeholders; take the actual credentials from your backup. Never commit `key.properties`.

Example release build using the weekly public version and its corresponding Android build number:

```sh
flutter build apk --release \
  --build-name 2026.46.1 \
  --build-number 2026460001 \
  --dart-define=SAATHI_DISTRIBUTION=standalone \
  --dart-define=SAATHI_UPDATE_OWNER=ss44 \
  --dart-define=SAATHI_UPDATE_REPO=Saathi-Flutter \
  --dart-define=SAATHI_UPDATE_CHANNEL=beta
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. Native Android compilation and device installation are separate checks; a Python signing-material test is not evidence that the APK built or that Android accepted an upgrade.

For an update test, install the earlier signed weekly release, then publish a higher weekly version using the same signing key. Checking an already-current build should report no update. Android still requires the user to allow installation from Saathi and approve the system installer.
