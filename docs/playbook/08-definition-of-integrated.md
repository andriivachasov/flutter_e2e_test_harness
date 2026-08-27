# 08 — Definition of integrated (machine-checkable)

Run the checker from the target repository root:

```sh
bash harness/tools/check_integration.sh .
```

It prints one `[PASS]`/`[FAIL]` line per criterion below and exits 1 on
any failure. An integration is complete when the checker passes **and**
`e2e run` is green twice in a row.

| # | Criterion | Checked by |
|---|---|---|
| 1 | `e2e.yaml` at the repo root; `harness/orchestrator`, `harness/test_support` vendored | file presence |
| 2 | `app.dir` exists; app depends on `patrol` and `e2e_test_support`; pubspec has a `patrol:` section | pubspec grep |
| 3 | Android: `PatrolJUnitRunner` in gradle and in an `androidTest/` entry point (`.java` or `.kt`) | file/grep |
| 4 | iOS: a `RunnerUITests` entry point (`.m` or `.swift`), `RunnerUITests` target in `Runner.xcodeproj`, Podfile block | file/grep |
| 5 | Firebase config files present when the build consumes them: `android/app/google-services.json` (gradle applies `google-services`), `ios/Runner/GoogleService-Info.plist` (referenced by the xcodeproj, macOS only) | file presence |
| 6 | App reads `E2E_*` dart-defines and sends `X-E2E-Test-Id` | `lib/` grep |
| 7 | App uses stable widget keys | `lib/` grep for `Key(`/`ValueKey(`/`Semantics(` |
| 8 | Manifest present with ≥ 1 `smoke`, ≥ 1 `single-user`, ≥ 1 `multi-user` test | manifest grep |
| 9 | Tests use `sync.guard` and `sync.step`; no `sleep()`/`Future.delayed` outside comments | `integration_test/` grep |
| 10 | Backend (if any): `E2E_TEST_MODE` gate and `X-E2E-Test-Id` logging present | `backend.dir` grep |
| 11 | `runs/` and `e2e.local.yaml` gitignored | `.gitignore` grep |
| 12 | `e2e list` parses the manifest; `e2e doctor` passes | runs both |

Not machine-checkable, verify by reading:

- Modules are plain functions with typed inputs/outputs; no test drives
  the UI to create fixture data.
- The first multi-user barrier has a ≥ 10 min timeout; a `done` barrier
  ends every multi-user test.
- Secrets (service-account key, `e2e.local.yaml`) never appear in a diff.
- The `/test/*` surface is locked, not merely flagged: the test backend
  binds to loopback and refuses non-loopback callers, failing closed
  (playbook 03 §3.2). `E2E_TEST_MODE` alone is an enable flag, not
  authentication. A backend that must listen off-host sends the
  `backend.test_header` secret instead.

## Acceptance run

```sh
cd harness/orchestrator && dart run bin/e2e.dart run && dart run bin/e2e.dart run
```

Both exit 0. Keep the second run's `runs/<id>/summary.html` as evidence —
pass `--keep-all` on that second run if you want it to survive retention
pruning (`run.keep_runs`, step 07).

Integrated. Later, when the reference repo has moved on:
[09-upgrading.md](09-upgrading.md).
