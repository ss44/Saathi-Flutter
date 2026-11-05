# Iris

A message-first Flutter client for Hermes Agent. Android is the first target; Linux and macOS are planned.

## Status

Early scaffold, not a functional Hermes client. The chat screen is a placeholder: settings and session buttons, real chat, session storage, sharing, and desktop tray behavior are not implemented. Generated Android, Linux and macOS runners use Flutter's example app identifiers and icons; replace them before releasing.

See the [product spec](docs/SPEC.md), [integration research](docs/INTEGRATION_NOTES.md), and [parallel work plan](.agents/WORK_PLAN.md).

## Develop

Flutter 3.47.9 is installed on this host at `/opt/data/tools/flutter`. To use it in the current shell:

```sh
export PATH="/opt/data/tools/flutter/bin:$PATH"
flutter pub get
flutter analyze
flutter test
```

For an actual device build, install the platform toolchain and use `flutter doctor -v` and `flutter run`. On this host, Android requires a JDK and Android SDK (including acceptance of the Android SDK terms); Linux requires clang, ninja, and GTK 3 development files. Building the macOS runner requires a Mac with Xcode. Those builds have not been verified here.
