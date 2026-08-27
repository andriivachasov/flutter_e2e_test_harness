#!/usr/bin/env bash
# M1 step 2: iOS native Patrol setup (RunnerUITests target, Podfile, pods)
# and an iOS test build as the gate. Idempotent. Logs to _e2e/logs/step2.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_e2e/logs"
exec > >(tee "$ROOT/_e2e/logs/step2.log") 2>&1
export PATH="$PATH:$HOME/.pub-cache/bin"
step() { echo; echo "=== $* ==="; }
fail() { echo; echo "STEP2 FAILED: $*"; exit 1; }
cd "$ROOT/example/app"

step "cocoapods"
pod --version || fail "CocoaPods not installed (brew install cocoapods)"

step "ruby xcodeproj gem"
if ! ruby -e "require 'xcodeproj'" 2>/dev/null; then
  echo "installing xcodeproj gem (user install)"
  gem install --user-install xcodeproj || fail "gem install xcodeproj"
  GEMBIN="$(ruby -e 'require "rubygems"; puts Gem.user_dir')/bin"
  export PATH="$PATH:$GEMBIN"
  ruby -e "require 'xcodeproj'" || fail "xcodeproj gem still not loadable"
fi
echo "xcodeproj gem ok"

step "regenerate ios/ without Swift Package Manager"
# The first config-only build injected SPM package references into the
# Xcode project; SPM is now disabled per-project in pubspec.yaml, so start
# from a clean pods-based ios/ scaffold. ios/ holds no hand-written state
# except what this script recreates below.
if [ ! -f ios/Podfile ]; then
  BK=$(mktemp -d)
  cp pubspec.yaml lib/main.dart analysis_options.yaml "$BK/"
  cp test/widget_test.dart "$BK/"
  rm -rf ios
  flutter create --project-name e2e_example_app --org com.example \
    --platforms ios . || fail "flutter create (ios regen)"
  cp "$BK/pubspec.yaml" pubspec.yaml
  cp "$BK/main.dart" lib/main.dart
  cp "$BK/analysis_options.yaml" analysis_options.yaml
  cp "$BK/widget_test.dart" test/widget_test.dart
  flutter pub get || fail "pub get after ios regen"
  flutter build ios --config-only --simulator || fail "flutter config-only build"
fi
[ -f ios/Podfile ] || fail "ios/Podfile still missing — check that pubspec.yaml has flutter.config.enable-swift-package-manager: false"

step "podfile: RunnerUITests block"
python3 "$ROOT/m1/podfile_patch.py" ios/Podfile || fail "podfile patch"

step "RunnerUITests.m"
mkdir -p ios/RunnerUITests
cat > ios/RunnerUITests/RunnerUITests.m <<'OBJC_EOF'
@import XCTest;
@import patrol;
@import ObjectiveC.runtime;

PATROL_INTEGRATION_TEST_IOS_RUNNER(RunnerUITests)
OBJC_EOF
echo "RunnerUITests.m written"

step "xcode project: RunnerUITests target + scheme"
(cd ios && ruby "$ROOT/m1/ios_target.rb") || fail "xcodeproj target creation"

step "pod install"
(cd ios && pod install) || fail "pod install"

step "patrol build ios (simulator) — the gate"
patrol build ios --target integration_test/cross_user_smoke_test.dart \
  --debug --simulator || fail "patrol build ios"

echo
echo "STEP2 OK"
