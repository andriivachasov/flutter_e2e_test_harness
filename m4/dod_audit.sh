#!/usr/bin/env bash
# M4 DoD (R14/R15): `e2e audit --runs 5` on the full suite emits a report;
# the deliberately flaky test (flaky_demo, fails on odd run seq numbers at
# step "flaky-assertion") is clustered as a consistent-step failure and,
# being tagged `quarantine`, never fails a run.
# Logs to _e2e/logs/m4_dod_audit.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_e2e/logs"
exec > >(tee "$ROOT/_e2e/logs/m4_dod_audit.log") 2>&1
export PATH="$PATH:$HOME/.pub-cache/bin:/opt/homebrew/bin"
fail() { echo; echo "DOD FAILED: $*"; exit 1; }
cd "$ROOT/harness/orchestrator"
RUNS=${RUNS:-5}
OUT="$ROOT/_e2e/logs/m4_dod_audit.run.out"

echo "=== e2e audit --runs $RUNS (full suite incl. quarantined flaky_demo)"
dart run bin/e2e.dart audit --runs "$RUNS" --keep-all > "$OUT" 2>&1
EXIT=$?
grep -A40 "^test " "$OUT" | head -40
AUDIT_DIR=$(grep -oE '→ \S+audit_\S+' "$OUT" | head -1 | cut -c3-)
[ -n "$AUDIT_DIR" ] || fail "audit dir never announced (exit $EXIT, see $OUT)"
[ -f "$AUDIT_DIR/audit.json" ] && [ -f "$AUDIT_DIR/audit.html" ] || fail "report files missing in $AUDIT_DIR"
# Every real test must be stable and flaky_demo is quarantined, so the audit
# itself must exit 0 (unstable = only non-quarantined tests).
[ "$EXIT" = 0 ] || fail "audit exited $EXIT (a non-quarantined test is unstable; see $AUDIT_DIR/audit.html)"

echo; echo "=== asserting on $AUDIT_DIR/audit.json"
python3 - "$AUDIT_DIR" "$RUNS" <<'EOF' || fail "audit report assertions"
import json, os, sys
d, runs = sys.argv[1], int(sys.argv[2])
r = json.load(open(os.path.join(d, 'audit.json')))
assert r['runCount'] == runs, r['runCount']
tests = {t['name']: t for t in r['tests']}
for name in ['smoke_sign_in', 'single_user_notes', 'cross_user_chat', 'seeded_notes_reset']:
    t = tests[name]
    assert t['verdict'] == 'stable' and t['passRate'] == 1.0, (name, t['verdict'], t['passRate'])
    assert t['durationMs']['p50'] and t['durationMs']['p95'] >= t['durationMs']['p50'], name
    assert t['steps'], f'{name}: no step timings reported'
f = tests['flaky_demo']
assert f['quarantined'] is True, 'flaky_demo not quarantined'
assert 0 < f['passRate'] < 1, f"flaky_demo pass rate {f['passRate']} (expected alternating)"
assert f['verdict'] == 'consistent-step', f['verdict']
assert f['clusters'] and f['clusters'][0]['step'] == 'flaky-assertion', f['clusters']
assert f['clusters'][0]['count'] == f['failed'], 'not every failure in the top cluster'
assert 'injected flake' in f['clusters'][0]['message'], f['clusters'][0]['message']
assert f['suggestQuarantine'] is False, 'already quarantined, must not be re-suggested'
ph = r['phases']
assert ph['runDurationMs']['p50'] and ph['deviceBootMsP50'], ph
# Every underlying run passed (exit 0) despite flaky_demo failing in some.
for run in r['runs']:
    s = json.load(open(os.path.join(d, '..', run, 'summary.json')))
    assert s['exitCode'] == 0 and s['passed'] is True, (run, s['exitCode'])
    fd = [t for t in s['tests'] if t['name'] == 'flaky_demo'][0]
    assert fd['quarantined'] is True
    if not fd['passed']:
        assert s['counts']['quarantinedFailed'] == 1, s['counts']
        assert fd['roles'][0]['failedStep'] == 'flaky-assertion', fd['roles'][0]
        assert any('quarantined test flaky_demo failed' in w for w in s['warnings']), s['warnings']
print(f"flaky_demo: {f['passed']}/{f['runs']} passed, cluster {f['clusters'][0]['count']}x at "
      f"'{f['clusters'][0]['step']}', verdict {f['verdict']}, quarantined; all other tests stable; "
      f"run p50 {ph['runDurationMs']['p50']//1000}s")
EOF

echo; echo "=== audit memory (D24)"
HIST="$ROOT/e2e-history"
[ -f "$HIST/$(basename "$AUDIT_DIR").json" ] || fail "no history entry for $(basename "$AUDIT_DIR") in $HIST"
grep -q "$(basename "$AUDIT_DIR")" "$HIST/HISTORY.md" || fail "HISTORY.md does not mention this audit"
ls "$AUDIT_DIR/runs/"*.summary.json >/dev/null 2>&1 || fail "audit report has no run snapshots"
echo "history entry + HISTORY.md updated; $(ls "$AUDIT_DIR/runs" | wc -l | tr -d ' ') run snapshots in the report"

echo; echo "DOD OK: audit report at $AUDIT_DIR/audit.html — flaky test clustered and quarantined, suite stable, history updated"
