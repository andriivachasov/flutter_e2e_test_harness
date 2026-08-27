# e2e-history — the suite's memory (D24)

`e2e audit` writes one small `audit_<timestamp>.json` here per audit and
regenerates `HISTORY.md` from all of them: per-test pass rate / p50 /
verdict over the last audits, plus regressions, improvements and suite
changes since the previous audit.

- **Commit this directory.** It is deliberately outside `runs/`, which is
  gitignored and pruned.
- **Merges never conflict on the entries** (unique file names). If
  `HISTORY.md` conflicts, keep both sides' JSON files and run
  `cd harness/orchestrator && dart run bin/e2e.dart history`.
- Do not edit `HISTORY.md` by hand; it is derived.
