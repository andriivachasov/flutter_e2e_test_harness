# ADR-020 (D20): Audit output and verdicts (2026-08-26, M4)

**Status:** accepted · 2026-08-26

## Decision

**`e2e audit --runs N` runs the selection N times (each a full run with its own bundle) and writes `runs/audit_<id>/audit.json` + `audit.html`.** Per test: pass rate, p50/p95/min/max duration, provisioning and launch p50, per-step p50/p95, failure clusters keyed by (failing step, number-normalized message). Verdicts: `stable`, `consistent-step` (top cluster ≥ 75 % of ≥ 2 failures → likely product bug), `scattered` (→ likely flaky infra), `single-failure` (inconclusive), `infra`. Exit 0 iff every non-quarantined test is `stable`

## Rationale

Implements R14's clustering rule as stated; every number links back to a run bundle. A deterministic fixture (`flaky_demo`, fails on odd `runs/.seq` numbers, quarantined) keeps the DoD reproducible instead of probabilistic.

## Where it lives

See `refined_requirements.md` (D20) and the playbook steps that apply it.
