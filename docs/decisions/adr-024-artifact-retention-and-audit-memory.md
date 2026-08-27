# ADR-024 (D24): Artifact retention and audit memory (2026-08-27)

**Status:** accepted · 2026-08-26

## Decision

**`runs/` (gitignored) keeps the newest `run.keep_runs` runs and `run.keep_audits` audit reports, pruned after every run/audit unless `--keep-all`. Audit reports are self-contained (they snapshot each run's `summary.json`). Every audit appends one small JSON entry to `run.history_dir` (`e2e-history/`, committed) and regenerates `HISTORY.md` there: per-test pass rate / p50 / verdict trend over the last audits and a "since the last audit" section (regressions: pass rate down, verdict worsened, p50 +20 %; improvements; new/removed/quarantined tests). `e2e history` regenerates it; doctor warns if the directory is gitignored**

## Rationale

Runs accumulate fast and audits need only their own runs; the memory that matters (how the suite trends) is tiny and belongs in version control. Per-audit files have unique names so parallel branches never conflict; the Markdown is derived and deterministic, so a conflict on it is resolved by regenerating rather than by hand.

## Where it lives

See `refined_requirements.md` (D24) and the playbook steps that apply it.
