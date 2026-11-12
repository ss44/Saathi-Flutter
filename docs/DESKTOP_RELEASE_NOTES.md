These are **unsigned desktop preview builds** of Saathi.

## Downloads
- **macOS universal ZIP:** Intel x86-64 and Apple Silicon arm64 in one `Saathi.app`. Extract the ZIP. This build is not Developer ID signed or notarized; Gatekeeper may block it. Do not disable system-wide security protections to run it.
- **Windows x64 ZIP:** extract the entire directory and run `Saathi/saathi.exe`. Keep all DLLs and the `data` directory beside it. Windows may require the Microsoft Visual C++ 2015–2022 x64 runtime and may show SmartScreen warnings because the executable is unsigned.
- **Linux x86-64 tar.gz:** extract it, keep the entire bundle together, and run `Saathi/saathi` in a graphical desktop session. Built on Ubuntu 22.04; requires compatible GTK 3, libsecret, libstdc++, and a running Secret Service/keyring for API-key storage. This is **64-bit x86**, not a 32-bit i386 build.

`SHA256SUMS` covers the three archives. Checksums detect corruption; they are not a substitute for code signing.

## Versioning
Versions use **ISO year.week.increment**, for example `2026.46.1` and tag `v2026.46.1`. The increment starts at 1 each ISO week and increases for subsequent releases that week. Weeks/increments are not zero-padded; the ISO week-year is used at New Year boundaries. This version is embedded in each binary; the workflow run number remains a separate internal platform build identifier.

Desktop automatic installation/replacement is not implemented; these artifacts have external self-updates disabled. Update by downloading and replacing the complete bundle. Backend compatibility, OS keychain behavior, and installation still require testing on your target machine. Mobile live-session login/bootstrap and native OpenClaw integration remain separate work.
