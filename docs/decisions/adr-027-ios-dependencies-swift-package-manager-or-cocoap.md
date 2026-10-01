# ADR-027 (D27): iOS dependencies: Swift Package Manager or CocoaPods (2026-10-01)

**Status:** accepted · 2026-08-26

## Decision

**`patrol_bootstrap.sh` keeps the iOS dependency manager the app already uses. An app on Swift Package Manager (Flutter's default; detected by `FlutterGeneratedPluginSwiftPackage` in `Runner.xcodeproj` and no `enable-swift-package-manager: false`) stays on it: the script links that package to `RunnerUITests`, as Patrol's SPM setup says, and needs no CocoaPods. Other apps keep the CocoaPods path (SPM off, `RunnerUITests` Podfile block, `pod install`). `--ios-deps=auto\|spm\|cocoapods` overrides the detection. The integration check and `e2e doctor` accept either**

## Rationale

The CocoaPods-only rule came from Patrol's docs at the time; Patrol supports SPM since 4.7. Forcing CocoaPods changes an app's iOS build for the harness's sake, breaks build steps written for SPM, and Firebase stops publishing to CocoaPods in October 2026. The race that SPM made visible (issue #14) is fixed by D28, not by avoiding SPM.

## Where it lives

See `refined_requirements.md` (D27) and the playbook steps that apply it.
