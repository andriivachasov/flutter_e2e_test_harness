#!/usr/bin/env bash
# M2 DoD (R3): on a machine without Xcode, `e2e doctor` must fail and say
# exactly what to install. Simulated by shadowing `xcrun` with a stub that
# behaves like the Command Line Tools' xcrun without Xcode (simctl missing).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_e2e/logs"
exec > >(tee "$ROOT/_e2e/logs/m2_dod_doctor_no_xcode.log") 2>&1
export PATH="$PATH:$HOME/.pub-cache/bin"
fail() { echo; echo "DOD FAILED: $*"; exit 1; }

SHADOW=$(mktemp -d)
cat > "$SHADOW/xcrun" <<'EOF'
#!/bin/sh
echo "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH" >&2
exit 72
EOF
chmod +x "$SHADOW/xcrun"

echo "=== e2e doctor with xcrun shadowed"
OUT=$(cd "$ROOT/harness/orchestrator" && PATH="$SHADOW:$PATH" dart run bin/e2e.dart doctor 2>&1)
EXIT=$?
echo "$OUT"
rm -rf "$SHADOW"

echo "=== asserting"
[ "$EXIT" -eq 1 ] || fail "doctor exit was $EXIT, expected 1"
echo "$OUT" | grep -q '^\[FAIL\] xcrun simctl (Xcode)' || fail "no FAIL line for Xcode"
echo "$OUT" | grep -q 'install Xcode from the App Store' || fail "fix line does not say to install Xcode"
echo "$OUT" | grep -q 'xcode-select -s /Applications/Xcode.app' || fail "fix line lacks xcode-select step"
echo "$OUT" | grep -q '^\[skip\] iOS simulator' || fail "simulator check should be skipped without Xcode"
echo "$OUT" | grep -q '^\[ok  \] adb' || fail "Android checks should still run"

echo
echo "DOD OK: doctor without Xcode exits 1 and names the exact install steps"
