These are **unsigned desktop preview builds** of Saathi.

## Downloads
- **macOS universal ZIP:** Intel x86-64 and Apple Silicon arm64 in one `Saathi.app`. Extract the ZIP. This build is not Developer ID signed or notarized; Gatekeeper may block it. Do not disable system-wide security protections to run it.
- **Windows x64 ZIP:** extract the entire directory and run `Saathi/saathi.exe`. Keep all DLLs and the `data` directory beside it. Windows may require the Microsoft Visual C++ 2015–2022 x64 runtime and may show SmartScreen warnings because the executable is unsigned.
- **Linux x86-64 tar.gz:** extract it, keep the entire bundle together, and run `Saathi/saathi` in a graphical desktop session. Built on Ubuntu 22.04; requires compatible GTK 3, libsecret, libstdc++, and a running Secret Service/keyring for API-key storage. This is **64-bit x86**, not a 32-bit i386 build.

`SHA256SUMS` covers the three archives. Checksums detect corruption; they are not a substitute for code signing.

## Versioning
UTC CalVer is `YYYY.M.D+BUILD` (for example, `2026.11.12+42`), with tag `vYYYY.M.D+BUILD`. Month/day are not zero-padded so Flutter's semantic-version parser accepts them. BUILD is the release workflow run number, or the explicit number from a validated date tag. The same values are embedded in each platform binary.

Desktop automatic installation/replacement is not implemented; these artifacts have external self-updates disabled. Update by downloading and replacing the complete bundle. Backend compatibility, OS keychain behavior, and installation still require testing on your target machine. Mobile live-session login/bootstrap and native OpenClaw integration remain separate work.
