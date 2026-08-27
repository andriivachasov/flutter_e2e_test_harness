#!/usr/bin/env bash
# M1 step 1: toolchain, platform folders, Android Patrol setup, deps,
# container-runnable tests, doctors. Idempotent — safe to re-run.
# Logs to _e2e/logs/step1.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_e2e/logs"
LOG="$ROOT/_e2e/logs/step1.log"
exec > >(tee "$LOG") 2>&1
export PATH="$PATH:$HOME/.pub-cache/bin"
step() { echo; echo "=== $* ==="; }
fail() { echo; echo "STEP1 FAILED: $*"; exit 1; }

step "toolchain versions"
flutter --version || fail "flutter not on PATH"
dart --version || fail "dart not on PATH"

step "patrol_cli"
if ! command -v patrol >/dev/null; then
  dart pub global activate patrol_cli || fail "activating patrol_cli"
fi
command -v patrol >/dev/null || fail "patrol still not on PATH (~/.pub-cache/bin)"
patrol --version

step "app platform folders"
cd "$ROOT/example/app"
if [ ! -d android ] || [ ! -d ios ]; then
  cp lib/main.dart /tmp/e2e_main.dart.bak
  cp pubspec.yaml /tmp/e2e_pubspec.yaml.bak
  flutter create --project-name e2e_example_app --org com.example \
    --platforms ios,android . || fail "flutter create"
  cp /tmp/e2e_main.dart.bak lib/main.dart
  cp /tmp/e2e_pubspec.yaml.bak pubspec.yaml
  echo "platform folders generated (lib/main.dart and pubspec.yaml preserved)"
else
  echo "android/ and ios/ already present"
fi

step "android: gradle patrol config"
GRADLE=android/app/build.gradle.kts
[ -f "$GRADLE" ] || GRADLE=android/app/build.gradle
[ -f "$GRADLE" ] || fail "no app-level gradle file found"
python3 "$ROOT/m1/gradle_patch.py" "$GRADLE" || fail "gradle patch"

step "android: MainActivityTest"
ATEST_DIR=android/app/src/androidTest/java/com/example/e2e_example_app
mkdir -p "$ATEST_DIR"
cat > "$ATEST_DIR/MainActivityTest.java" <<'JAVA_EOF'
package com.example.e2e_example_app;

import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameters;
import pl.leancode.patrol.PatrolJUnitRunner;

@RunWith(Parameterized.class)
public class MainActivityTest {
    @Parameters(name = "{0}")
    public static Object[] testCases() {
        PatrolJUnitRunner instrumentation = (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.setUp(MainActivity.class);
        instrumentation.waitForPatrolAppService();
        return instrumentation.listDartTests();
    }

    public MainActivityTest(String dartTestName) {
        this.dartTestName = dartTestName;
    }

    private final String dartTestName;

    @Test
    public void runDartTest() {
        PatrolJUnitRunner instrumentation = (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.runDartTest(dartTestName);
    }
}
JAVA_EOF
echo "MainActivityTest.java written"

step "dependency resolution"
flutter pub get || fail "app pub get"
(cd "$ROOT/harness/test_support" && dart pub get) || fail "test_support pub get"
(cd "$ROOT/harness/orchestrator" && dart pub get) || fail "orchestrator pub get"
(cd "$ROOT/example/backend" && dart pub get) || fail "backend pub get"

step "unit tests: backend"
(cd "$ROOT/example/backend" && dart test) || fail "backend unit tests"
step "unit tests: orchestrator"
(cd "$ROOT/harness/orchestrator" && dart test) || fail "orchestrator unit tests"

step "static analysis"
(cd "$ROOT/example/app" && flutter analyze) || fail "app analyze"
(cd "$ROOT/harness/orchestrator" && dart analyze) || fail "orchestrator analyze"
(cd "$ROOT/harness/test_support" && dart analyze) || fail "test_support analyze"
(cd "$ROOT/example/backend" && dart analyze) || fail "backend analyze"

step "patrol doctor"
patrol doctor || echo "(patrol doctor reported issues — review above)"

step "e2e doctor"
cd "$ROOT" && dart run --directory harness/orchestrator bin/e2e.dart doctor \
  || echo "(e2e doctor reported issues — review above)"

echo
echo "STEP1 OK"
