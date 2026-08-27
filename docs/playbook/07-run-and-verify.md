# 07 — Run, read the artifacts, audit

```sh
cd harness/orchestrator
alias e2e="dart run bin/e2e.dart"
e2e doctor                     # environment + config; must be all-ok
e2e list                       # tests from the manifest
e2e run                        # everything
e2e run --test <name>          # one test
e2e run --tag smoke            # by tag (repeatable)
e2e run --keep-all             # skip retention pruning
e2e audit --runs 5             # reliability + timing report
e2e devices · e2e prune
```

Exit codes: `run` 0 all passed · 1 test failures · 2 infra/config error.
`audit` 0 every non-quarantined test stable · 1 unstable · 2 infra.
The first log line of a run is `run <id> (seq N) → <run dir>`; the last
ones are `summary: <dir>/summary.html` and `result: X/Y passed, exit N` —
parse those rather than guessing directory names.

`e2e doctor`'s "no leftover harness processes" check lists backend,
`patrol test`, recorder, emulator and orchestrator processes — orphans
from an interrupted run *or* a run active in another shell. Devices are
shared: never start a second run while one is active.

## What a run does, in order

1. Auth emulator (unless `firebase.mode` is `real`/`none`), backend
   (unless `command: []`), sync server, provisioner prepare.
2. Boots/reuses the devices in parallel (they stay booted afterwards; the
   next run is fast).
3. Writes the single Patrol bundle, then schedules tests over the device
   pool: a test starts as soon as each of its roles has a free device.
4. Per test: assign a pool account per role → reset its server-side data,
   seed → wipe app data → one `patrol test` process per role with the
   `E2E_*` defines → reset its data again.
5. Environment death (backend or emulator exits) aborts everything with
   exit 2 and a complete bundle — no hang; every external call has a
   timeout.

## The artifact bundle — `runs/<timestamp>_<id>/`

```
summary.html          cards per test/role, verdicts, step timeline, screenshots
summary.json          the same for agents: verdicts, users, steps, failedStep,
                      failureMessage, appLaunchMs, timings, env (redacted), seq
orchestrator.log      what the harness did
backend.log           all requests (JSON lines) — and <test>/backend.log per test
firebase.log          Auth emulator output (emulator mode)
<test>/<role>/video.mp4 · app.log · test.log · screenshots/NN_label.png
```

Reading a failure: open `summary.html` → the failing role → "failed at step
X: message" → screenshots (`..._failure.png` is taken by `guard`) →
`test.log` (Patrol/flutter output, secrets redacted) → `app.log` →
`<test>/backend.log`.

## Audit (R14/R15)

`e2e audit --runs N [--test|--tag]` repeats the selection N times and
writes `runs/audit_<id>/audit.{json,html}`: pass rate, p50/p95, launch and
per-step timings, failure clusters keyed by (failing step, normalized
message) with verdicts `stable` / `consistent-step` (same step every time →
likely a product bug) / `scattered` (→ likely flaky infra) /
`single-failure` / `infra`, and a quarantine suggestion. Tag suggested
tests `quarantine` to stop them blocking runs while they stay visible —
[../patterns/flake-quarantine.md](../patterns/flake-quarantine.md).

**Memory across audits.** Each audit also writes `e2e-history/<auditId>.json`
(commit these — one tiny file per audit, never a merge conflict) and
regenerates `e2e-history/HISTORY.md`: the trend table (pass rate · p50 per
test per audit) and "since the last audit" regressions/improvements/suite
changes. `e2e history` regenerates the document; if it ever conflicts in a
merge, keep both sides' JSON files and regenerate.

**Retention.** `runs/` is gitignored and pruned to `run.keep_runs` runs
and `run.keep_audits` audit reports after every run/audit (`--keep-all`
skips pruning). Audit reports snapshot their runs' summaries, so pruning
runs never breaks a report.

## Real Firebase project (optional)

To run against a dedicated test-only Firebase project: put its
`project_id` and Web `api_key` (both public identifiers) plus a
`pool_password` in `e2e.local.yaml`, enable Email/Password in the console,
then `E2E_FIREBASE_MODE=real e2e run`. The same pool accounts are
registered by the app on the first run and reused afterwards; their data
is reset server-side around every test. No admin credentials are involved.
One run per project at a time (the pool is shared).

## Done when

`e2e run` exits 0 with every test `PASS` in `summary.html`, and a second
run is green too (repeatability is the point).

Next: [08-definition-of-integrated.md](08-definition-of-integrated.md)
