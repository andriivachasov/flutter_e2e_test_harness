# ADR-019 (D19): Flake quarantine semantics (2026-08-26, M4)

**Status:** accepted · 2026-08-26

## Decision

**A test tagged with `run.quarantine_tag` (default `quarantine`) runs and is reported (`QUARANTINED FAIL`, a run warning, `counts.quarantinedFailed`) but does not affect the exit code.** `e2e audit` suggests candidates (`0 < pass rate < 1`, not yet tagged); adding the tag is a manifest edit, never automatic

## Rationale

"Known-flaky tests don't block runs but stay visible" (R14) literally; tag-based so the quarantine list lives with the tests and in version control.

## Where it lives

See `refined_requirements.md` (D19) and the playbook steps that apply it.
