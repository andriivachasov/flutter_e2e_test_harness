#!/usr/bin/env bash
# Patrol native bootstrap for ANY Flutter app (playbook step 05). Idempotent.
#
#   bash harness/tools/patrol_bootstrap.sh <app_dir> [--skip-ios] [--skip-android]
#                                          [--ios-deps=auto|spm|cocoapods]
#
# Android: PatrolJUnitRunner + orchestrator in app/build.gradle(.kts),
#          MainActivityTest.java in the app's package.
# iOS:     RunnerUITests target + scheme entry, then per dependency manager:
#          - Swift Package Manager (an app whose Runner already links
#            FlutterGeneratedPluginSwiftPackage): the package is linked to
#            RunnerUITests too (Patrol >= 4.7 SPM setup); SPM stays on.
#          - CocoaPods (SPM disabled in pubspec, or no SPM wiring): Podfile
#            block, pod install.
#          --ios-deps=auto (default) picks by those rules.
# Both:    `patrol:` section in pubspec.yaml (app_name, package, bundle id).
# Gate:    `patrol build android|ios` is NOT run here; `e2e run` builds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?usage: patrol_bootstrap.sh <app_dir> [--skip-ios] [--skip-android]}"
shift || true
SKIP_IOS=0; SKIP_ANDROID=0; IOS_DEPS=auto
for a in "$@"; do case "$a" in
  --skip-ios) SKIP_IOS=1;; --skip-android) SKIP_ANDROID=1;;
  --ios-deps=auto|--ios-deps=spm|--ios-deps=cocoapods) IOS_DEPS="${a#--ios-deps=}";;
  *) echo "unknown option: $a"; exit 2;;
esac; done
export PATH="$PATH:$HOME/.pub-cache/bin"
step() { echo; echo "=== $* ==="; }
fail() { echo; echo "PATROL BOOTSTRAP FAILED: $*"; exit 1; }
cd "$APP" || fail "app dir $APP not found"
[ -f pubspec.yaml ] || fail "$APP has no pubspec.yaml"

step "patrol_cli"
# patrol_cli must match the app's patrol (docs/playbook/02, "Known-good versions").
PATROL_CLI_VERSION=4.8.0
if ! command -v patrol >/dev/null || ! patrol --version 2>/dev/null | grep -q "v$PATROL_CLI_VERSION"; then
  dart pub global activate patrol_cli "$PATROL_CLI_VERSION" || fail "activating patrol_cli $PATROL_CLI_VERSION"
fi
patrol --version

step "identify the app"
GRADLE=android/app/build.gradle.kts; [ -f "$GRADLE" ] || GRADLE=android/app/build.gradle
[ -f "$GRADLE" ] || fail "no android/app/build.gradle(.kts) — run: flutter create --platforms ios,android ."
PKG=$(grep -oE 'applicationId *=? *"[^"]+"' "$GRADLE" | head -1 | grep -oE '"[^"]+"' | tr -d '"')
[ -n "$PKG" ] || PKG=$(grep -oE 'namespace *=? *"[^"]+"' "$GRADLE" | head -1 | grep -oE '"[^"]+"' | tr -d '"')
[ -n "$PKG" ] || fail "could not read applicationId/namespace from $GRADLE"
BUNDLE=$(grep -oE 'PRODUCT_BUNDLE_IDENTIFIER = [^;]+' ios/Runner.xcodeproj/project.pbxproj 2>/dev/null \
  | grep -v RunnerTests | head -1 | sed 's/PRODUCT_BUNDLE_IDENTIFIER = //; s/"//g')
[ -n "$BUNDLE" ] || fail "could not read PRODUCT_BUNDLE_IDENTIFIER from ios/Runner.xcodeproj"
APPNAME=$(grep -E '^name:' pubspec.yaml | head -1 | sed 's/name: *//')
# iOS dependency manager: SPM when the app already uses it (Runner links
# Flutter's generated plugin package and the pubspec does not opt out),
# otherwise CocoaPods.
if [ "$IOS_DEPS" = auto ]; then
  if ! grep -qE 'enable-swift-package-manager:[[:space:]]*false' pubspec.yaml \
     && grep -q FlutterGeneratedPluginSwiftPackage ios/Runner.xcodeproj/project.pbxproj 2>/dev/null; then
    IOS_DEPS=spm
  else
    IOS_DEPS=cocoapods
  fi
fi
echo "android package: $PKG"; echo "ios bundle id:   $BUNDLE"; echo "pubspec name:    $APPNAME"
echo "ios deps:        $IOS_DEPS"

step "pubspec: patrol section (+ SPM off for CocoaPods)"
python3 - "$APPNAME" "$PKG" "$BUNDLE" "$IOS_DEPS" <<'PY' || fail "pubspec patch"
import re, sys, pathlib
name, pkg, bundle, ios_deps = sys.argv[1:5]
p = pathlib.Path('pubspec.yaml'); s = p.read_text()
if not re.search(r'^patrol:\s*$', s, re.M):
    s = s.rstrip('\n') + f"\n\npatrol:\n  app_name: {name}\n  android:\n    package_name: {pkg}\n  ios:\n    bundle_id: {bundle}\n"
    print('pubspec: patrol section added')
else:
    print('pubspec: patrol section present')
if ios_deps == 'cocoapods' and 'enable-swift-package-manager' not in s:
    m = re.search(r'^flutter:\s*\n', s, re.M)
    if not m:
        s = s.rstrip('\n') + "\nflutter:\n  config:\n    enable-swift-package-manager: false\n"
    else:
        s = s[:m.end()] + "  config:\n    # Patrol's iOS setup is CocoaPods-based; SPM is opted out per project.\n    enable-swift-package-manager: false\n" + s[m.end():]
    print('pubspec: swift package manager disabled')
p.write_text(s)
PY

if [ "$SKIP_ANDROID" = 0 ]; then
  step "android: gradle"
  python3 "$HERE/gradle_patch.py" "$GRADLE" || fail "gradle patch"
  step "android: MainActivityTest.java"
  ATEST_DIR="android/app/src/androidTest/java/$(echo "$PKG" | tr . /)"
  # Detect a prior entry point by CONTENT, not filename: an existing Kotlin
  # MainActivityTest.kt must not get a .java sibling (duplicate class).
  ATEST_EXISTING=$(grep -rl PatrolJUnitRunner android/app/src/androidTest 2>/dev/null | head -1)
  if [ -n "$ATEST_EXISTING" ]; then
    echo "skipped (exists): $ATEST_EXISTING already uses PatrolJUnitRunner"
  else
    mkdir -p "$ATEST_DIR"
    cat > "$ATEST_DIR/MainActivityTest.java" <<JAVA_EOF
package $PKG;

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
    echo "written $ATEST_DIR/MainActivityTest.java"
  fi
fi

if [ "$SKIP_IOS" = 0 ]; then
  step "ios: prerequisites"
  if [ "$IOS_DEPS" = cocoapods ] || [ -f ios/Podfile ]; then
    pod --version >/dev/null || fail "CocoaPods not installed (brew install cocoapods)"
  fi
  if ! ruby -e "require 'xcodeproj'" 2>/dev/null; then
    gem install --user-install xcodeproj || fail "gem install xcodeproj"
    export PATH="$PATH:$(ruby -e 'require "rubygems"; puts Gem.user_dir')/bin"
    ruby -e "require 'xcodeproj'" || fail "xcodeproj gem still not loadable"
  fi
  if [ "$IOS_DEPS" = cocoapods ]; then
    step "ios: stale SwiftPM patrol package"
    # SPM off (above) stops Flutter generating
    # ios/Flutter/ephemeral/Packages/.packages/patrol-<version>/, so a project
    # that wired Patrol as a local Swift package can no longer resolve
    # dependencies ("Could not resolve package dependencies"). Drop the
    # reference before anything tries to build.
    if [ "$(uname -s)" != "Darwin" ] || [ ! -d ios/Runner.xcodeproj ]; then
      echo "xcodeproj: skipped (nothing to clean)"
    else
      (cd ios && ruby "$HERE/ios_spm_cleanup.rb") || fail "xcodeproj SPM cleanup"
    fi
    step "ios: Podfile"
    flutter pub get || fail "flutter pub get"
    if [ ! -f ios/Podfile ]; then
      # A project created with SPM has no Podfile; a config-only build with
      # SPM disabled (pubspec) generates one.
      flutter build ios --config-only --simulator || fail "flutter build ios --config-only"
    fi
    [ -f ios/Podfile ] || fail "ios/Podfile still missing"
    python3 "$HERE/podfile_patch.py" ios/Podfile || fail "podfile patch"
  else
    step "ios: Swift Package Manager"
    flutter pub get || fail "flutter pub get"
    if ! grep -q FlutterGeneratedPluginSwiftPackage ios/Runner.xcodeproj/project.pbxproj; then
      # Flutter adds its generated plugin package to Runner on an SPM build.
      flutter build ios --config-only --simulator || fail "flutter build ios --config-only"
    fi
    grep -q FlutterGeneratedPluginSwiftPackage ios/Runner.xcodeproj/project.pbxproj \
      || fail "Runner does not link FlutterGeneratedPluginSwiftPackage (is Swift Package Manager enabled? flutter config --enable-swift-package-manager)"
    if [ -f ios/Podfile ]; then
      # SPM apps may still have CocoaPods-only plugins in a Podfile.
      python3 "$HERE/podfile_patch.py" ios/Podfile || fail "podfile patch"
    fi
  fi
  step "ios: RunnerUITests"
  # Same content-based guard as Android: an existing .m or .swift *Patrol*
  # UI-test bootstrap (and any hand-written notes in it) is left alone. The
  # marker must be Patrol's own — Xcode's stock UI Testing Bundle template
  # also declares `class RunnerUITests`, and skipping on that would leave a
  # non-Patrol target that builds a UI-test bundle with no Patrol tests.
  UITEST_EXISTING=$(grep -rlE 'PATROL_INTEGRATION_TEST_IOS_(RUNNER|MODULE)' ios/RunnerUITests 2>/dev/null | head -1)
  if [ -n "$UITEST_EXISTING" ]; then
    echo "skipped (exists): $UITEST_EXISTING is already a Patrol UI-test entry point"
  else
    mkdir -p ios/RunnerUITests
    cat > ios/RunnerUITests/RunnerUITests.m <<'OBJC_EOF'
@import XCTest;
@import patrol;
@import ObjectiveC.runtime;

PATROL_INTEGRATION_TEST_IOS_RUNNER(RunnerUITests)
OBJC_EOF
    echo "written ios/RunnerUITests/RunnerUITests.m"
  fi
  SPM_ARG=""; [ "$IOS_DEPS" = spm ] && SPM_ARG="--spm"
  (cd ios && ruby "$HERE/ios_target.rb" "$BUNDLE" $SPM_ARG) || fail "xcodeproj target creation"
  if [ -f ios/Podfile ]; then
    step "ios: pod install"
    (cd ios && pod install) || fail "pod install"
  fi
fi

echo; echo "PATROL BOOTSTRAP OK ($APP)"
