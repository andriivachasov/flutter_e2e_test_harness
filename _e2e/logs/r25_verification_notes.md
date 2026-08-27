# R25 / D26 — fail-fast across roles, verification notes (2026-08-27, 1.1.0)

Three levels of evidence: unit, negative control, and a real two-device run.

## 1. Contract tests (fast, permanent)

`harness/orchestrator/test/fail_fast_test.dart` — the real `SyncClient`
against a real `SyncServer`, so both halves of the wire contract are checked
against each other rather than against a mock. The orchestrator dev-depends
on `test_support` for this; `test_support` itself stays dependency-free.

Eight cases: barrier / event / value each released by a partner failure;
failure published *before any wait exists* (the early-failure race);
own-failure never releases the failing role; `failFast: false` per wait and
per client; first failure wins over a cascade; another test's namespace does
not leak; already-arrived data still wins over the marker.

`harness/orchestrator/test/sync_server_test.dart` gained one case pinning the
wire shape (`failed: {role, message}` on `/sync/count` and the 404s of
`/sync/event` and `/sync/kv`; absent before any failure; namespaced).

Full orchestrator suite after the change: **42 tests, all passing.**

## 2. Negative control — the tests are not vacuous

Commenting out the single publishing line in `sync_server.dart`
(`_failures.putIfAbsent(...)`) makes `fail_fast_test.dart` **hang to its
5-minute deadlines** instead of failing fast — which is exactly the
pre-1.1.0 behaviour the feature removes. Restored immediately after.

## 3. Real two-device run

Temporary fixture (`fail_fast_probe`, since removed — file and manifest
entry both deleted): A on iOS launches then throws; B on Android launches
then waits on `barrier('app-ready', timeout: 10 minutes)`.

`dart run bin/e2e.dart run --test fail_fast_probe --keep-all`, run
`2026-08-27T1739_72`, **71 s wall clock** — against a 10-minute budget B
would otherwise have burned in full.

From `summary.json`:

```
role A | failedStep: 'deliberate-failure'
   message: Bad state: deliberate failure in role A (R25 probe)

role B | failedStep: 'wait-for-partner'
   message: PartnerFailure: role "A" failed: Bad state: deliberate failure
            in role A (R25 probe)
```

B's error names A and carries A's message, and B's `failedStep` records
where it was waiting — which is what makes the summary readable: the true
cause first, the collateral second.

## 4. No regression

Full suite immediately before the probe, run `2026-08-27T1735_329`:
**5/6 passed, exit 0** (`flaky_demo` failed as designed — quarantined,
run seq 19 is odd). `cross_user_chat` PASSED, which is the test that
actually exercises the modified `waitForValue` / `barrier` / `emit` paths
across two devices.

Not re-run in `real` Firebase mode — this change touches neither auth nor
the provisioner. `docs/releasing.md` still gates `dev` → `main` on both
modes being green.
