These are **desktop preview builds and a release-signed standalone Android APK** of Saathi. Desktop builds remain unsigned; Android is signed with the project's persistent standalone signing identity, not a debug key. This is not a Google Play release.

## Downloads
- **macOS universal ZIP:** Intel x86-64 and Apple Silicon arm64 in one `Saathi.app`. Extract the ZIP. This build is not Developer ID signed or notarized; Gatekeeper may block it. Do not disable system-wide security protections to run it.
- **Windows x64 ZIP:** extract the entire directory and run `Saathi/saathi.exe`. Keep all DLLs and the `data` directory beside it. Windows may require the Microsoft Visual C++ 2015–2022 x64 runtime and may show SmartScreen warnings because the executable is unsigned.
- **Linux x86-64 tar.gz:** extract it, keep the entire bundle together, and run `Saathi/saathi` in a graphical desktop session. Built on Ubuntu 22.04; requires compatible GTK 3, libsecret, libstdc++, and a running Secret Service/keyring for API-key storage. This is **64-bit x86**, not a 32-bit i386 build.
- **Android APK:** download `Saathi-VERSION-android.apk` and approve Android's installer. The universal APK supports the Flutter ARM/ARM64/x86-64 targets. It checks this repository's beta releases and offers verified APK downloads followed by the system installer; installation is never silent. Android may ask you to allow installs from Saathi. Keep the same signing identity for future upgrades.

`SHA256SUMS` covers the three desktop archives, Android APK, and `saathi-update-beta.json`. Checksums detect corruption; they are not a substitute for code signing. The signing backup and credentials are never release assets.

## Versioning
Versions use **ISO year.week.increment**, for example `2026.46.1` and tag `v2026.46.1`. The increment starts at 1 each ISO week and increases for subsequent releases that week. Weeks/increments are not zero-padded; the ISO week-year is used at New Year boundaries. Desktop builds use the separate workflow run number internally. Android uses the deterministic `YYYYWWIIII` versionCode, e.g. `2026460001`, so updates remain monotonic across weeks and reruns. Combined releases allow increments 1–9999 and must fit Android's versionCode limit.

Desktop automatic installation/replacement is not implemented; these artifacts have external self-updates disabled. Update by downloading and replacing the complete bundle. Backend compatibility, OS keychain behavior, and installation still require testing on your target machine. Mobile live-session login/bootstrap and native OpenClaw integration remain separate work.
