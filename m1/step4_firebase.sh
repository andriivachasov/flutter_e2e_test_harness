#!/usr/bin/env bash
# M3 step 4: Firebase CLI for the Auth emulator. Idempotent — safe to re-run.
# Logs to _e2e/logs/step4_firebase.log
#
# Only the Auth emulator is used, which is implemented inside the CLI itself:
# no Java runtime is needed (Firestore/Database emulators would need one).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_e2e/logs"
exec > >(tee "$ROOT/_e2e/logs/step4_firebase.log") 2>&1
step() { echo; echo "=== $* ==="; }
fail() { echo; echo "STEP4 FAILED: $*"; exit 1; }

step "firebase CLI"
if command -v firebase >/dev/null; then
  echo "already installed: $(command -v firebase) ($(firebase --version))"
elif command -v brew >/dev/null; then
  brew install firebase-cli || fail "brew install firebase-cli"
elif command -v npm >/dev/null; then
  npm install -g firebase-tools || fail "npm install -g firebase-tools"
else
  fail "neither Homebrew nor npm found; install the CLI per https://firebase.google.com/docs/cli#install-cli-mac-linux (standalone binary works too) and put 'firebase' on PATH, or set firebase.cli in e2e.yaml"
fi
command -v firebase >/dev/null || fail "firebase still not on PATH"
firebase --version

step "Auth emulator smoke test (demo project, no login needed)"
TMP="$(mktemp -d)"
cat > "$TMP/firebase.json" <<'EOF'
{"emulators":{"auth":{"host":"127.0.0.1","port":39199},"hub":{"port":39400},"logging":{"port":39500},"ui":{"enabled":false},"singleProjectMode":true}}
EOF
(cd "$TMP" && CI=true firebase emulators:start --only auth --project demo-step4 \
  --config firebase.json --non-interactive > "$TMP/emu.log" 2>&1 &)
for _ in $(seq 1 60); do
  if curl -s -m 2 http://127.0.0.1:39199/ | grep -q '"ready": *true'; then READY=1; break; fi
  sleep 1
done
pkill -f "emulators:start --only auth --project demo-step4" || true
[ "${READY:-0}" = 1 ] || { cat "$TMP/emu.log"; fail "Auth emulator did not start"; }
echo "Auth emulator started and stopped cleanly"
rm -rf "$TMP"

step "e2e doctor"
cd "$ROOT/harness/orchestrator" && dart run bin/e2e.dart doctor \
  || echo "(e2e doctor reported issues — review above)"

echo
echo "STEP4 OK"
