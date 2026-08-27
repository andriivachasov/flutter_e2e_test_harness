#!/usr/bin/env bash
# Machine-checkable "definition of integrated" (playbook step 08).
#   bash harness/tools/check_integration.sh [repo_root]
# Prints one PASS/FAIL line per criterion; exit 1 if any FAIL.
set -uo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
export PATH="$PATH:$HOME/.pub-cache/bin:/opt/homebrew/bin"
FAILS=0
ok()   { echo "[PASS] $*"; }
bad()  { echo "[FAIL] $*"; FAILS=$((FAILS+1)); }
yaml() { python3 - "$ROOT/e2e.yaml" "$1" <<'PY'
import sys, re
path, key = sys.argv[1:3]
# tiny reader for "section:\n  key: value" (no yaml dependency)
sec, k = key.split('.')
cur = None
for line in open(path):
    if re.match(r'^\S', line): cur = line.split(':')[0].strip()
    m = re.match(r'^\s+' + re.escape(k) + r':\s*(.*?)\s*(#.*)?$', line)
    if cur == sec and m:
        print(m.group(1).strip().strip('"\'')); break
PY
}

[ -f "$ROOT/e2e.yaml" ] && ok "e2e.yaml at repo root" || bad "e2e.yaml missing at $ROOT"
[ -f "$ROOT/harness/orchestrator/bin/e2e.dart" ] && ok "harness/orchestrator vendored" || bad "harness/orchestrator missing"
[ -f "$ROOT/harness/test_support/lib/test_support.dart" ] && ok "harness/test_support vendored" || bad "harness/test_support missing"

APP="$ROOT/$(yaml app.dir)"; [ -d "$APP" ] && ok "app.dir exists ($APP)" || { bad "app.dir does not exist ($APP)"; APP=""; }
if [ -n "$APP" ]; then
  grep -qE '^\s+patrol:' "$APP/pubspec.yaml" && ok "app depends on patrol" || bad "app pubspec lacks patrol dependency"
  grep -qE '^\s+e2e_test_support:' "$APP/pubspec.yaml" && ok "app depends on e2e_test_support" || bad "app pubspec lacks e2e_test_support (path: harness/test_support)"
  grep -qE '^patrol:' "$APP/pubspec.yaml" && ok "pubspec has patrol: section" || bad "pubspec lacks patrol: section (bootstrap tool adds it)"
  grep -q PatrolJUnitRunner "$APP"/android/app/build.gradle* 2>/dev/null && ok "android gradle configured for Patrol" || bad "android gradle lacks PatrolJUnitRunner"
  grep -rq PatrolJUnitRunner "$APP/android/app/src/androidTest" 2>/dev/null && ok "android test entry point present (.java or .kt)" || bad "no androidTest entry point using PatrolJUnitRunner"
  grep -rqE 'PATROL_INTEGRATION_TEST_IOS_(RUNNER|MODULE)' "$APP/ios/RunnerUITests" 2>/dev/null && ok "iOS RunnerUITests entry point present (.m or .swift)" || bad "iOS RunnerUITests entry point missing"
  grep -q RunnerUITests "$APP/ios/Runner.xcodeproj/project.pbxproj" 2>/dev/null && ok "iOS RunnerUITests target in xcodeproj" || bad "iOS xcodeproj lacks RunnerUITests target"
  grep -q "RunnerUITests" "$APP/ios/Podfile" 2>/dev/null && ok "Podfile has RunnerUITests block" || bad "Podfile lacks RunnerUITests block"
  # Gitignored in most Flutter repos: a fresh clone/worktree builds for
  # minutes and then dies at :app:processDebugGoogleServices.
  # Flavored apps keep these outside the canonical path (android/app/src/<flavor>/,
  # a per-flavor iOS directory copied in by a build phase), so search the tree.
  found_anywhere() { # <root> <filename>
    [ -d "$1" ] && find "$1" -name "$2" \
      -not -path '*/Pods/*' -not -path '*/build/*' \
      -not -path '*/.symlinks/*' -not -path '*/ephemeral/*' \
      -print -quit 2>/dev/null | grep -q .
  }
  if grep -rqE "google-services" "$APP"/android/app/build.gradle* "$APP"/android/build.gradle* "$APP"/android/settings.gradle* 2>/dev/null; then
    found_anywhere "$APP/android/app/src" "google-services.json" && ok "google-services.json present" \
      || bad "google-services.json missing (gitignored in most repos: flutterfire configure, or copy it from another checkout)"
  fi
  if [ "$(uname)" = Darwin ] && grep -q "GoogleService-Info.plist" "$APP/ios/Runner.xcodeproj/project.pbxproj" 2>/dev/null; then
    found_anywhere "$APP/ios" "GoogleService-Info.plist" && ok "GoogleService-Info.plist present" \
      || bad "GoogleService-Info.plist missing (gitignored in most repos: flutterfire configure, or copy it from another checkout)"
  fi
  grep -rqE "E2E_BACKEND_URL|TestContext" "$APP/lib" 2>/dev/null && ok "app reads its e2e configuration from dart-defines" || bad "app lib/ never reads E2E_* dart-defines"
  grep -rq "X-E2E-Test-Id" "$APP/lib" 2>/dev/null && ok "app sends X-E2E-Test-Id (log correlation)" || bad "app never sends X-E2E-Test-Id"
  grep -rqE "Key\('|ValueKey\(|Semantics\(" "$APP/lib" 2>/dev/null && ok "app uses stable widget keys" || bad "no widget keys found in app lib/"
  MANIFEST="$APP/$(yaml app.tests_manifest)"; [ "$(yaml app.tests_manifest)" ] || MANIFEST="$APP/integration_test/e2e_tests.yaml"
  if [ -f "$MANIFEST" ]; then
    ok "test manifest present ($MANIFEST)"
    grep -qE 'tags:.*single-user' "$MANIFEST" && ok "manifest has a single-user test" || bad "manifest has no single-user test"
    grep -qE 'tags:.*multi-user' "$MANIFEST" && ok "manifest has a multi-user test" || bad "manifest has no multi-user test"
    grep -qE 'tags:.*smoke' "$MANIFEST" && ok "manifest has a smoke test" || bad "manifest has no smoke test"
  else
    bad "test manifest missing ($MANIFEST)"
  fi
  grep -rq "sync.guard" "$APP/integration_test" 2>/dev/null && ok "tests use sync.guard (failure screenshot + report)" || bad "tests do not use sync.guard"
  grep -rq "sync.step" "$APP/integration_test" 2>/dev/null && ok "tests report steps (sync.step)" || bad "tests do not report steps"
  grep -rhE "sleep\(|Future\.delayed\(" "$APP/integration_test" 2>/dev/null | grep -vqE '^\s*//' \
    && bad "tests contain sleep()/Future.delayed — use sync primitives or poll-with-timeout" || ok "no sleep()-based coordination in tests"
fi

CMD="$(yaml backend.command)"
if [ -n "$CMD" ] && [ "$CMD" != "[]" ]; then
  BDIR="$ROOT/$(yaml backend.dir)"; [ -d "$BDIR" ] && ok "backend.dir exists ($BDIR)" || bad "backend.dir missing ($BDIR)"
  grep -rq "E2E_TEST_MODE" "$BDIR" 2>/dev/null && ok "backend gates /test/* on E2E_TEST_MODE" || bad "backend never checks E2E_TEST_MODE"
  grep -rq "x-e2e-test-id\|X-E2E-Test-Id" "$BDIR" 2>/dev/null && ok "backend logs X-E2E-Test-Id" || bad "backend never logs X-E2E-Test-Id"
else
  ok "backend.command empty: harness starts no backend (seeding/resets unavailable)"
fi

if [ -f "$ROOT/.gitignore" ]; then
  grep -q "^runs/" "$ROOT/.gitignore" && ok "runs/ gitignored" || bad "runs/ not in .gitignore"
  grep -q "e2e.local.yaml" "$ROOT/.gitignore" && ok "e2e.local.yaml gitignored" || bad "e2e.local.yaml not in .gitignore"
  HIST="$(yaml run.history_dir)"; HIST="${HIST:-e2e-history}"
  grep -qE "^/?${HIST}/?$" "$ROOT/.gitignore" && bad "$HIST/ (audit memory) must NOT be gitignored" || ok "$HIST/ (audit memory) not gitignored"
else
  bad ".gitignore missing"
fi

if command -v dart >/dev/null && [ -f "$ROOT/harness/orchestrator/bin/e2e.dart" ]; then
  (cd "$ROOT/harness/orchestrator" && dart run bin/e2e.dart list --config "$ROOT/e2e.yaml" >/dev/null 2>&1) \
    && ok "e2e list parses the manifest" || bad "e2e list fails (run it for the error)"
  (cd "$ROOT/harness/orchestrator" && dart run bin/e2e.dart doctor --config "$ROOT/e2e.yaml" >/dev/null 2>&1) \
    && ok "e2e doctor passes" || bad "e2e doctor reports failures (run it)"
fi

echo
[ "$FAILS" = 0 ] && { echo "INTEGRATION CHECK OK"; exit 0; } || { echo "INTEGRATION CHECK: $FAILS failure(s)"; exit 1; }
