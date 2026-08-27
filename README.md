# e2e_test_harness

Flexible, reliable e2e test harness for Flutter apps (iOS + Android), designed
to be integrated into existing apps by AI agents. See `refined_requirements.md`
and `implementation_plan.md` for the full picture. **To integrate the harness
into your own app, start at [`docs/README.md`](docs/README.md)** — the
playbook (`docs/playbook/00-overview.md` → `08-definition-of-integrated.md`),
patterns, ADRs and troubleshooting; `harness/tools/patrol_bootstrap.sh` and
`harness/tools/check_integration.sh` do the mechanical parts.

This repo (`git@github.com:andriivachasov/flutter_e2e_test_harness.git`) is
the **reference repository**: a separate app repo doesn't depend on it at
build time — an agent clones it, copies `harness/` (and, for convenience,
`docs/`) into the target repo, and follows the playbook from there. See
[playbook/02-vendor-the-harness.md §2.1](docs/playbook/02-vendor-the-harness.md)
for the exact clone/copy commands. Quick version:

```sh
git clone --depth 1 git@github.com:andriivachasov/flutter_e2e_test_harness.git /tmp/flutter_e2e_test_harness
```

## Layout

| Path | What |
|---|---|
| `harness/orchestrator/` | `e2e` CLI: boots devices, backend and Firebase Auth emulator, provisions users, seeds, runs tests, collects artifacts |
| `harness/test_support/` | app-side package: TestContext (incl. the role's pool account), SyncClient (barriers, events, kv, screenshots, steps, seed, account reset) — zero deps |
| `harness/tools/` | `patrol_bootstrap.sh <app>` (native Patrol setup for any app), `check_integration.sh` (machine-checkable definition of integrated) |
| `docs/` | integration playbook for AI agents, patterns, ADRs, troubleshooting |
| `example/backend/` | Dart shelf backend (HTTP/1.1+JSON, Firebase ID-token auth, `/test/*` endpoints under `E2E_TEST_MODE=1`) |
| `example/app/` | example Flutter app: email/password sign-in, notes (single-user), chat (two-user, polling) |
| `example/seeds/` | named seed profiles (`<name>.json`) |
| `e2e.yaml` | harness configuration (committed, credential-free) |
| `e2e.local.yaml` | machine-local overrides and secrets (gitignored; template committed) |
| `runs/` | per-run artifacts (gitignored, keep-last-20) |

## One-time setup (macOS)

```sh
bash m1/step1_setup.sh      # toolchain, patrol_cli, platform folders, deps
bash m1/step2_ios.sh        # Patrol iOS bootstrap
bash m1/step3_devices.sh    # "iPhone 16" simulator + e2e_pixel AVD
bash m1/step4_firebase.sh   # firebase CLI (Auth emulator; no Java needed)
cd harness/orchestrator && dart run bin/e2e.dart doctor   # must be all-ok
```

## Running

```sh
cd harness/orchestrator
alias e2e="dart run bin/e2e.dart"
e2e doctor          # verify environment + config
e2e list            # tests from example/app/integration_test/e2e_tests.yaml
e2e run             # everything (Auth emulator, pool accounts)
e2e run --test cross_user_chat
e2e run --tag smoke
e2e audit --runs 5  # reliability + timing report (R14/R15)
```

Every run writes `runs/<run-id>/` with `summary.html` (humans),
`summary.json` (agents), per-test/per-role `video.mp4`, `screenshots/`,
`app.log`, `test.log`, plus `backend.log` (and a per-test slice),
`firebase.log` and `orchestrator.log`. Exit codes: 0 all passed · 1 test
failures · 2 infra/config error.

## Users, seeding, resets (M3)

Every test role gets a **pool account** before the body runs
(`TestContext.user`): `<scope>-<role>@<email_domain>` with one shared
password, scope = test name (or a `users: {role: label}` manifest override
to share accounts within a feature). The harness never touches Firebase
Auth: the app registers the account through its regular sign-up flow on
first use and signs in afterwards ("Continue"). Seeds
(`seed: {A: user-with-history}`) and account resets are keyed by email.

| mode | where | needs |
|---|---|---|
| `emulator` (default) | per-run Auth emulator, `demo-` project | the firebase CLI |
| `real` | dedicated test-only project (D6) | `project_id` + Web `api_key` + a `pool_password` in `e2e.local.yaml` — no admin credentials |
| `none` | app without Firebase | nothing |

```sh
E2E_FIREBASE_MODE=real e2e run
```

Resets: the app's on-device data is wiped before every role (R9a,
`executor.reset_app_data`); tests can ask for a server-side account reset
(`sync.resetAccount()`, R9b) or mid-test seeding (`sync.seed('profile')`).

## Self-audit (M4)

`e2e audit --runs N [--test|--tag]` runs the selection N times and writes
`runs/audit_<id>/audit.json` + `audit.html`: per-test pass rate, p50/p95
duration, build+install+launch and per-step timings (tests mark steps with
`sync.step('name')` and wrap their body in `sync.guard(...)`), and failure
clusters keyed by failing step + message — same step every time ⇒ likely a
product bug, scattered ⇒ likely flaky infra. Tests tagged `quarantine`
(`run.quarantine_tag`) still run and are reported but never fail a run;
the audit suggests candidates. `flaky_demo` is a deliberately flaky,
quarantined fixture that fails on odd run sequence numbers. Every audit
also appends `e2e-history/<auditId>.json` (commit it) and regenerates
`e2e-history/HISTORY.md` — the suite's memory: trend per test and
regressions since the previous audit. `runs/` is gitignored and pruned to
`run.keep_runs` runs / `run.keep_audits` audits.

## Definition-of-done scripts

```sh
bash m2/dod_kill_backend.sh     # backend killed mid-test → exit 2, complete bundle
bash m2/dod_doctor_no_xcode.sh  # doctor without Xcode → exact install steps
bash m3/dod_both_modes.sh       # all R21 tests pass in emulator AND real mode
bash m4/dod_audit.sh            # audit --runs 5: flaky test clustered + quarantined
```
