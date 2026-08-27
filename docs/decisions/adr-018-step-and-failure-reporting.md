# ADR-018 (D18): Step and failure reporting (2026-08-26, M4)

**Status:** accepted · 2026-08-26

## Decision

**Tests mark module boundaries with `sync.step('name')` and wrap their body in `sync.guard(...)`, which on failure takes the failure screenshot and reports the failure (step + message) to the orchestrator.** The orchestrator times steps (`summary.json` → `roles[].steps`) and records `failedStep` / `failureMessage`

## Rationale

One convention gives both R15 per-module durations and R14 failing-step clustering without parsing Patrol's log; modules stay plain functions (R7). Reporting is fire-and-forget and never fails a test.

## Where it lives

See `refined_requirements.md` (D18) and the playbook steps that apply it.
