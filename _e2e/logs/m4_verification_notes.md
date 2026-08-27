# M4 verification log — 2026-08-26

Scope (implementation_plan.md §3, M4): `e2e audit` — N-run execution,
per-test pass rate, p50/p95 durations, failure clustering by failing step,
flake-quarantine tag honored by `run` (R14); timing breakdown of device
boot / install / module phases (R15).

DoD status:
- `m4/dod_audit.sh` — PASS (second attempt, see below): `e2e audit --runs 5`
  on the full suite; report at `runs/audit_2026-08-26T1617/`;
  `flaky_demo` 3/5 passed, verdict `consistent-step`, one cluster
  `2× at "flaky-assertion": Expected: true Actual: <false> injected flake:
  run seq # is odd`, quarantined and not re-suggested; the four product
  tests `stable` at 100 %; every underlying run exited 0; audit exit 0.
  Log: `_e2e/logs/m4_dod_audit.log`.
- Unit level: `test/audit_test.dart` covers percentile, message
  normalization, clustering verdicts (stable / consistent-step / scattered /
  single-failure), quarantine handling and the suggestion list on synthetic
  summaries. 35 orchestrator tests pass.
- Manual: two consecutive `e2e run --test flaky_demo` runs → seq 1 `FAIL
  (quarantined)`, run exit 0 with a warning and
  `counts.quarantinedFailed: 1`; seq 2 PASS. The failed role's summary
  carries `appLaunchMs` (31.3 s), `steps` (launch 1.5 s, sign-in 2.1 s,
  flaky-assertion 7.6 s), `failedStep: flaky-assertion` and the expect
  message; `summary.html` shows `QUARANTINED FAIL` and "failed at step".

## What was built

- **Step + failure reporting** (D18): `SyncClient.step(name)`,
  `SyncClient.reportFailure(error)`, `SyncClient.guard(body)`;
  sync-server routes `/harness/step` and `/harness/failure`; the runner
  keeps per-role progress and turns it into `RoleOutcome.steps[]`
  (durations = gap to the next step, last step ends at role finish),
  `failedStep` (the step in progress when the failure was reported, else
  the last step), `failureMessage` (first line of the reported error, or
  "timed out" / "aborted by orchestrator").
- **Launch timing** (R15): the collector's launch poll now always runs
  (video optional) and stamps `appLaunchedAt`; `RoleOutcome.appLaunchMs` =
  role start → app first seen running (build + install + launch).
- **Run sequence**: `runs/.seq` is a monotonic counter; `summary.json.seq`
  and the `E2E_RUN_SEQ` define / `TestContext.runSeq` expose it. Used by
  the flaky fixture to fail deterministically on odd runs.
- **Quarantine** (D19): `run.quarantine_tag` (default `quarantine`);
  `TestOutcome.quarantined`, `blocking`; exit code ignores quarantined
  failures; warning + `counts.quarantinedFailed`; amber `QUARANTINED FAIL`
  badge.
- **Audit** (D20, `audit/audit.dart`): `e2e audit --runs N [--test|--tag]
  [--keep-all]` runs `Runner` N times (never pruning between runs), then
  `buildAuditReport` over the runs' `summary.json`: per-test runs / passed
  / failed / infra / passRate / p50 p95 min max / provisionMs p50 /
  appLaunchMs p50 / per-step p50 p95 / clusters / verdict / interpretation
  / suggestQuarantine; per-run phases (run p50/p95, backend, auth
  emulator, provisioner prepare, device boot per platform); a
  `quarantineSuggestion` list. Written to `runs/audit_<id>/audit.json` and
  `audit.html` (clusters link to the runs' `summary.html`), plus a stdout
  table. Retention leaves `audit_*` directories alone.
- **Fixture**: `flaky_demo` (tags `flaky-demo, quarantine`) — launch,
  sign-in, then `expect(runSeq.isEven)` at step `flaky-assertion`.
- **Tests** now use `guard` + `step` at every module boundary
  (`launch`, `sign-in`, `notes` / `verify-seeded` / `account-reset` /
  `re-seed` / `rendezvous` / `open-chat` / `exchange` / `done-barrier`).

## Design notes

- Clustering key = (failing step, message with digits collapsed to `#`,
  whitespace squeezed, 140 chars). Verdict `consistent-step` when the top
  cluster holds ≥ 75 % of ≥ 2 failed roles; `scattered` otherwise (≥ 2);
  `single-failure` for one; `infra` when only infra outcomes failed.
- `appLaunchMs` merges build, install and launch because Patrol builds
  inside `patrol test`; splitting it needs `executor.prebuild` (still a
  known gap).
- Audit exit code: 0 iff every non-quarantined test is `stable` — so the
  audit doubles as a "is the suite trustworthy" gate.

## What broke and what changed

### First DoD attempt: the cluster message lost the informative part
`normalizeMessage` kept only the first line of the failure, which for an
`expect` failure is `Expected: true` — the reason lives on the third line.
The DoD asserted the reason was in the cluster and failed. Now the whole
message is kept (stack frames stripped, whitespace collapsed, 200 chars);
`summary.html` shows the same one-line form. The audit itself had already
produced the right verdicts on the first attempt (2/5, consistent-step).

## Result

Audit `runs/audit_2026-08-26T1617` (5 runs, ~17 min):

    test                   runs  pass   rate     p50     p95  verdict
    cross_user_chat           5     5   100%   85.6s   88.2s  stable
    flaky_demo                5     3    60%   35.7s   48.7s  consistent-step [quarantined]
        2× at "flaky-assertion": Expected: true Actual: <false> injected flake: run seq # is odd
    seeded_notes_reset        5     5   100%   37.1s   37.4s  stable
    single_user_notes         5     5   100%   37.4s   38.6s  stable
    smoke_sign_in             5     5   100%   85.1s   89.6s  stable
    run p50 203.0s · backend start 0.6s · auth emulator 2.5s · device boot android 0.1s, ios 0.2s

Where the time goes (R15): a full run is ~200 s; `cross_user_chat` and
whichever single-user test lands on the same device after it dominate
(~85 s each, of which build+install+launch is ~30 s per role on warm
caches); the emulator, backend and provisioning are negligible (< 4 s).
The obvious next win is `executor.prebuild` (build once per platform,
install per test), still a known gap.
