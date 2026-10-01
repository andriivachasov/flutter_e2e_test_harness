# ADR-028 (D28): One `patrol test` build at a time per app dir (2026-10-01)

**Status:** accepted · 2026-08-26

## Decision

**The orchestrator starts a role's `patrol test` only after the previous role started in the same run has launched its app (or ended). Builds overlap no longer; tests still run concurrently once their apps are up**

## Rationale

Concurrent `patrol test` runs in one app dir rewrite the same Flutter-generated files (`Package.swift`, `Generated.xcconfig`, ephemeral packages); with SPM, xcodebuild fails with "Package.swift was modified during the build" (issue #14), and the race exists on CocoaPods too. Waiting for launch rather than for the whole role keeps multi-role tests possible, since role A blocks on a barrier until role B is up.

## Where it lives

See `refined_requirements.md` (D28) and the playbook steps that apply it.
