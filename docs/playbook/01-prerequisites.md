# 01 — Machine prerequisites

Everything here is checked by `e2e doctor` (step 07) with an actionable
message per item. Install what is missing; re-run doctor until all-ok.

| Need | Check | Install |
|---|---|---|
| Flutter + Dart | `flutter --version` | https://docs.flutter.dev/get-started |
| patrol_cli 4.x | `patrol --version` | `dart pub global activate patrol_cli` and add `~/.pub-cache/bin` to PATH |
| Xcode (full app, not CLT) — iOS only | `xcrun simctl help` | App Store → `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch && xcodebuild -downloadPlatform iOS` |
| CocoaPods — iOS only | `pod --version` | `brew install cocoapods` |
| Android SDK + platform-tools + emulator | `adb version`, `$ANDROID_HOME/emulator/emulator -list-avds` | Android Studio, or `sdkmanager "platform-tools" "emulator" "system-images;android-35;google_apis;arm64-v8a"`. Only `adb` must be on PATH: the harness finds `emulator` under `$ANDROID_HOME` / `$ANDROID_SDK_ROOT` / `~/Library/Android/sdk`. |
| Firebase CLI — only if `firebase.mode: emulator` | `firebase --version` | `brew install firebase-cli` (or `npm i -g firebase-tools`). No Java needed for the Auth emulator. |

## Devices

The harness expects one iOS simulator and one Android AVD, named in
`e2e.yaml` (`devices.ios.name`, `devices.android.avd`). Defaults:
`"iPhone 16"` and `e2e_pixel`. Create them if missing:

```sh
# iOS: newest installed runtime
RUNTIME=$(xcrun simctl list runtimes | grep -E '^iOS' | tail -1 | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9.-]+')
xcrun simctl create "iPhone 16" com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$RUNTIME"

# Android: API 35 Google APIs image, GPU forced to host (see below)
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
"$SDK/cmdline-tools/latest/bin/sdkmanager" "system-images;android-35;google_apis;arm64-v8a"
"$SDK/cmdline-tools/latest/bin/avdmanager" create avd -n e2e_pixel -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_7
printf 'hw.gpu.enabled=yes\nhw.gpu.mode=host\n' >> "$HOME/.android/avd/e2e_pixel.avd/config.ini"
```

**Why `hw.gpu.mode=host`:** with the default (`auto` → software Vulkan)
the emulator drops its adb connection during screenshots; measured 5 of 8
runs failing before the fix. On a machine without a usable GPU driver set
`devices.android.gpu: swangle` in `e2e.yaml` instead.

The reference repository's `setup/step3_devices.sh` does the above
idempotently; copy it if useful.

## Done when

`flutter`, `dart`, `patrol`, `adb`, `emulator`, `xcrun simctl` (macOS),
`pod` (macOS) and — for emulator mode — `firebase` all run; the two
devices exist. You will confirm with `e2e doctor` after step 02.

Next: [02-vendor-the-harness.md](02-vendor-the-harness.md)
