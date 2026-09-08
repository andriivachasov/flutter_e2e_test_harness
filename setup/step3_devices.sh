#!/usr/bin/env bash
# Setup step 3 preflight: ensure the devices in e2e.yaml exist —
# iOS simulator "iPhone 16" and Android AVD "e2e_pixel".
# Idempotent. Logs to _e2e/logs/step3_devices.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_e2e/logs"
exec > >(tee "$ROOT/_e2e/logs/step3_devices.log") 2>&1
step() { echo; echo "=== $* ==="; }
fail() { echo; echo "STEP3 FAILED: $*"; exit 1; }

IOS_NAME="iPhone 16"
IOS_DEVICETYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-16"
AVD_NAME="e2e_pixel"
SYS_IMAGE="system-images;android-35;google_apis;arm64-v8a"

step "iOS simulator \"$IOS_NAME\""
if xcrun simctl list devices available | grep -q "$IOS_NAME ("; then
  echo "already exists"
else
  # Use the newest installed iOS runtime.
  RUNTIME=$(xcrun simctl list runtimes | grep -E '^iOS' \
    | tail -1 | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9.-]+')
  [ -n "$RUNTIME" ] || fail "no iOS simulator runtime installed"
  xcrun simctl create "$IOS_NAME" "$IOS_DEVICETYPE" "$RUNTIME" \
    || fail "simctl create"
  echo "created ($RUNTIME)"
fi

step "Android SDK tools"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
EMULATOR="$SDK/emulator/emulator"
[ -x "$AVDMANAGER" ] || fail "avdmanager not found at $AVDMANAGER"
[ -x "$EMULATOR" ] || fail "emulator not found at $EMULATOR"
echo "sdk: $SDK"

# avdmanager needs a JRE; fall back to Android Studio's bundled JDK.
# (macOS ships a /usr/bin/java stub, so probe that java actually runs.)
if [ -z "${JAVA_HOME:-}" ] && ! java -version >/dev/null 2>&1; then
  ASJBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  [ -x "$ASJBR/bin/java" ] || fail "no Java runtime (needed by avdmanager); install a JDK or Android Studio"
  export JAVA_HOME="$ASJBR"
  echo "JAVA_HOME=$JAVA_HOME (Android Studio JBR)"
fi

step "Android AVD \"$AVD_NAME\""
if "$EMULATOR" -list-avds | grep -qx "$AVD_NAME"; then
  echo "already exists"
else
  [ -d "$SDK/system-images/$(echo "$SYS_IMAGE" | cut -d';' -f2)" ] \
    || fail "system image not installed: $SYS_IMAGE (install via sdkmanager)"
  echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYS_IMAGE" \
    -d pixel_7 || fail "avdmanager create avd"
  "$EMULATOR" -list-avds | grep -qx "$AVD_NAME" || fail "AVD not listed after create"
  echo "created"
fi

step "AVD gpu mode"
# Software Vulkan (lavapipe) wedges the adb link when screencap runs against
# a compositing app — measured 5/8 runs failing vs 0/8 on host GPU. Force
# host GPU in the AVD config as well as at boot (devices.android.gpu).
CONFIG="$HOME/.android/avd/$AVD_NAME.avd/config.ini"
if [ -f "$CONFIG" ]; then
  python3 - "$CONFIG" <<'PY'
import sys
p = sys.argv[1]
lines = [l for l in open(p).read().splitlines()
         if not l.startswith(('hw.gpu.enabled', 'hw.gpu.mode'))]
lines += ['hw.gpu.enabled=yes', 'hw.gpu.mode=host']
open(p, 'w').write('\n'.join(sorted(lines)) + '\n')
print('config.ini: hw.gpu.mode=host')
PY
else
  echo "WARN: $CONFIG not found; set hw.gpu.mode=host manually"
fi

echo
echo "STEP3 DEVICES OK"
