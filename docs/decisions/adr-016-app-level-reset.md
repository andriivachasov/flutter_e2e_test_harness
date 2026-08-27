# ADR-016 (D16): App-level reset (2026-08-26, M3)

**Status:** accepted · 2026-08-26

## Decision

**R9a = Android `pm clear <package>` / iOS `simctl uninstall <bundle>` before every test role (`executor.reset_app_data: true`); Patrol reinstalls.** The example app persists its session on device so a leaked session would be visible (every test starts by asserting the sign-in page)

## Rationale

Cheapest complete wipe on each platform; the persisted session turns "reset happened" into an assertion instead of a belief.

## Where it lives

See `refined_requirements.md` (D16) and the playbook steps that apply it.
