#!/usr/bin/env bash
# M2 DoD (R6): killing the backend mid-test must yield a failed run with a
# complete artifact bundle and a non-zero exit — and no hang.
#
# Runs `e2e run --test cross_user_chat`, waits until both apps are on
# screen (first test-requested screenshot per role), SIGKILLs the backend,
# then asserts on the outcome. Logs to _e2e/logs/m2_dod_kill_backend.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_e2e/logs"
exec > >(tee "$ROOT/_e2e/logs/m2_dod_kill_backend.log") 2>&1
export PATH="$PATH:$HOME/.pub-cache/bin"
fail() { echo; echo "DOD FAILED: $*"; exit 1; }
TEST=cross_user_chat
RUN_LIMIT_S=420   # hard ceiling: an aborted run must finish well within this

echo "=== starting run"
(cd "$ROOT/harness/orchestrator" && dart run bin/e2e.dart run --test $TEST --keep-all \
  > "$ROOT/_e2e/logs/m2_dod_kill_backend.run.out" 2>&1; echo "RUN_EXIT=$?" \
  >> "$ROOT/_e2e/logs/m2_dod_kill_backend.run.out") &
RUNNER_PID=$!
OUT="$ROOT/_e2e/logs/m2_dod_kill_backend.run.out"

# Wait for the run dir to be announced.
for _ in $(seq 1 60); do
  RUN_DIR=$(grep -oE '→ \S+' "$OUT" 2>/dev/null | head -1 | cut -c3-)
  [ -n "${RUN_DIR:-}" ] && break
  sleep 1
done
[ -n "${RUN_DIR:-}" ] || fail "run dir never announced"
echo "run dir: $RUN_DIR"

echo "=== waiting for both apps to be on screen (home-visible screenshots)"
for _ in $(seq 1 240); do
  if ls "$RUN_DIR/$TEST/A/screenshots/"01_*.png "$RUN_DIR/$TEST/B/screenshots/"01_*.png >/dev/null 2>&1; then
    break
  fi
  kill -0 $RUNNER_PID 2>/dev/null || fail "run ended before the apps came up"
  sleep 1
done
ls "$RUN_DIR/$TEST/A/screenshots/"01_*.png "$RUN_DIR/$TEST/B/screenshots/"01_*.png >/dev/null 2>&1 \
  || fail "apps did not come up within 240s"

BACKEND_PID=$(pgrep -f "bin/server.dart --port" | head -1)
[ -n "$BACKEND_PID" ] || fail "backend process not found"
echo "=== killing backend pid $BACKEND_PID"
kill -9 "$BACKEND_PID"
KILLED_AT=$(date +%s)

echo "=== waiting for the run to finish (limit ${RUN_LIMIT_S}s)"
while kill -0 $RUNNER_PID 2>/dev/null; do
  if [ $(( $(date +%s) - KILLED_AT )) -gt $RUN_LIMIT_S ]; then
    kill $RUNNER_PID 2>/dev/null
    fail "run did not finish within ${RUN_LIMIT_S}s after the backend died (hang)"
  fi
  sleep 2
done
ELAPSED=$(( $(date +%s) - KILLED_AT ))
EXIT=$(grep -oE 'RUN_EXIT=[0-9]+' "$OUT" | tail -1 | cut -d= -f2)
echo "run exit: $EXIT, ${ELAPSED}s after the kill"
tail -8 "$OUT"

echo "=== asserting"
[ "$EXIT" != "0" ] || fail "run exited 0 despite backend death"
python3 - "$RUN_DIR" "$TEST" <<'EOF' || fail "artifact bundle incomplete"
import json, os, sys
run, test = sys.argv[1], sys.argv[2]
s = json.load(open(os.path.join(run, 'summary.json')))
assert s['passed'] is False, 'summary says passed'
assert s['exitCode'] != 0, 'summary exitCode 0'
t = [x for x in s['tests'] if x['name'] == test][0]
assert t['passed'] is False
assert t['infraError'] and 'backend' in t['infraError'], t['infraError']
assert any('backend exited unexpectedly' in w for w in s['warnings']), s['warnings']
for f in ['summary.html', 'backend.log', 'orchestrator.log', f'{test}/backend.log']:
    p = os.path.join(run, f); assert os.path.getsize(p) >= 0, f
for role in ['A', 'B']:
    d = os.path.join(run, test, role)
    for f in ['video.mp4', 'app.log', 'test.log', 'screenshots/00_start.png', 'screenshots/99_end.png']:
        p = os.path.join(d, f)
        assert os.path.exists(p) and os.path.getsize(p) > 0, f'{role}/{f} missing/empty'
    assert any(x.startswith('01_') for x in os.listdir(os.path.join(d, 'screenshots')))
print('bundle complete; infraError =', t['infraError'])
EOF

echo
echo "DOD OK: backend kill → exit $EXIT in ${ELAPSED}s with a complete bundle at $RUN_DIR"
