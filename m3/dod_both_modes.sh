#!/usr/bin/env bash
# M3 DoD (revised for D23): all R21 tests pass in BOTH Firebase modes —
#   emulator  (Auth emulator, demo project, nothing to configure)
#   real      (dedicated real test project: project_id + Web API key; D6)
# with the same fixed user pool; the app registers accounts on first use.
# Logs to _e2e/logs/m3_dod_both_modes.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_e2e/logs"
exec > >(tee "$ROOT/_e2e/logs/m3_dod_both_modes.log") 2>&1
export PATH="$PATH:$HOME/.pub-cache/bin:/opt/homebrew/bin"
fail() { echo; echo "DOD FAILED: $*"; exit 1; }
cd "$ROOT/harness/orchestrator"

run_mode() {  # $1 = label, rest = env assignments
  local label="$1"; shift
  local out="$ROOT/_e2e/logs/m3_dod_both_modes.$label.out"
  echo; echo "=== $label: e2e run ($*)"
  env "$@" dart run bin/e2e.dart run --keep-all > "$out" 2>&1
  local exit=$?
  tail -3 "$out"
  local run_dir
  run_dir=$(grep -oE '→ \S+' "$out" | head -1 | cut -c3-)
  [ -n "$run_dir" ] || fail "$label: run dir never announced"
  [ "$exit" = 0 ] || fail "$label: exit $exit (see $out, $run_dir/summary.html)"
  python3 - "$run_dir" "$label" <<'EOF' || fail "$label: summary assertions"
import json, os, sys
run, label = sys.argv[1], sys.argv[2]
s = json.load(open(os.path.join(run, 'summary.json')))
assert s['passed'] and s['exitCode'] == 0, 'not passed'
names = sorted(t['name'] for t in s['tests'])
for required in ['cross_user_chat', 'seeded_notes_reset', 'single_user_notes', 'smoke_sign_in', 'returning_user']:
    assert required in names, names
mode = s['environment']['provisioner']['mode']
assert mode == 'pool', mode
assert s['environment']['firebase']['mode'] == ('real' if label == 'real' else 'emulator')
for t in s['tests']:
    # M4: quarantined fixtures (flaky_demo) may fail without failing the run.
    assert t['passed'] or t.get('quarantined'), t['name']
    for r in t['roles']:
        assert r['user'] and r['user']['email'] and r['user']['scope'], f"{t['name']}/{r['role']} has no pool account"
        assert 'password' not in json.dumps(r), 'password leaked into summary'
        assert r['user']['email'].startswith(r['user']['scope'].lower().replace('_', '-')), r['user']
        d = os.path.join(run, r['artifacts']['dir'])
        for f in ['app.log', 'test.log', 'screenshots/00_start.png', 'screenshots/99_end.png']:
            assert os.path.getsize(os.path.join(d, f)) > 0, f'{d}/{f}'
        assert 'redacted' in open(os.path.join(d, 'test.log')).readline(), 'password not redacted in test.log'
seeded = [t for t in s['tests'] if t['name'] == 'seeded_notes_reset'][0]
assert seeded['roles'][0]['seedProfile'] == 'user-with-history'
chat = [t for t in s['tests'] if t['name'] == 'cross_user_chat'][0]
assert {r['user']['scope'] for r in chat['roles']} == {'chat'}, 'users: override not applied'
if label == 'emulator':
    assert os.path.getsize(os.path.join(run, 'firebase.log')) > 0, 'firebase.log missing'
print(f"{label}: {s['counts']['passed']}/{s['counts']['total']} passed "
      f"({s['counts']['quarantinedFailed']} quarantined failure(s)), provisioner={mode}, "
      f"users per role present, secrets redacted")
EOF
  echo "$label OK: $run_dir"
  RUN_IDS="${RUN_IDS:-} $(basename "$run_dir")"
}

run_mode emulator E2E_FIREBASE_MODE=emulator
run_mode real     E2E_FIREBASE_MODE=real

echo; echo "DOD OK: all R21 tests pass in emulator and real mode with the fixed user pool"
