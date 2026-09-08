# Project: e2e_test_harness

Flutter e2e test harness (iOS + Android, Patrol-based), built to be integrated
into existing apps by AI agents. This is the **reference repository**: an app
repo never depends on it at build time — it copies `harness/` (and `docs/`)
out of a clone and follows the playbook.

Read before changing anything:

- `README.md` — what this repo is, layout, how to run it
- `refined_requirements.md` — requirements R1–R25 and the decision log D1–D26
  (source of truth for both; ADRs under `docs/decisions/` are generated from
  §2 by `docs/decisions/regen.py` — edit the table there, regenerate here)
- `docs/README.md` → `docs/playbook/00-overview.md` … `09-upgrading.md` — the
  integration playbook, plus `docs/patterns/`, `docs/troubleshooting.md` and
  `docs/releasing.md`

## Setup and running

Setup from a cold checkout (macOS, idempotent, logs to `_e2e/logs/`):
`bash setup/step1_setup.sh` → `bash setup/step2_ios.sh` → `bash setup/step3_devices.sh`
→ `bash setup/step4_firebase.sh` (firebase CLI; Auth emulator only, no Java)
→ `e2e doctor` must be all-ok.

CLI (`cd harness/orchestrator && dart run bin/e2e.dart <cmd>`):
`doctor` · `run [--test <name>] [--tag <tag>]... [--keep-all]` ·
`audit --runs N [--test|--tag] [--keep-all]` · `history` · `list` ·
`devices` · `prune` (runs + audits).
Exit codes: 0 passed · 1 test failures (audit: unstable non-quarantined
test) · 2 infra.

The full suite is green in both Firebase modes: `dart run bin/e2e.dart run`
→ 5 product tests + the quarantined `flaky_demo`, exit 0 (~3.5 min warm on
the emulator); `E2E_FIREBASE_MODE=real dart run bin/e2e.dart run` → the same
against a real test project. `cross_user_chat` takes both devices; the
single-user tests shard across them (R19a).

## How tests are defined

Tests come from the manifest `example/app/integration_test/e2e_tests.yaml`
(name, target, tags, roles `ios|android|any`, optional `seed: {role:
profile}`, optional `users: {role: label}`) — not from code. Every role gets
a pool account before the body runs; tests read it from `TestContext.user`
and the app registers it on first use. Suite: `smoke_sign_in`,
`single_user_notes`, `returning_user` (register → sign-out → sign-in asserted
via the app's `auth_mode_*` banner), `cross_user_chat` (A ios / B android,
shared `chat` accounts), `seeded_notes_reset`; modules in
`integration_test/modules/` (`launchApp`/`continueAs`/`signOut`,
`addNote`/`expectNotes`, `openChat`/`sendMessage`/`waitForMessage`). Seed
profiles: `example/seeds/<name>.json` (the format is the backend's contract,
see its README).

Test bodies are wrapped in `sync.guard(...)` (failure report + failure
screenshot, in that order — the report releases partner roles and the
screenshot can take tens of seconds) and mark module boundaries with
`sync.step('name')` — that is where step timings (R15) and the failing step
for clustering (R14) come from. Tests tagged `quarantine` run and are
reported but never fail the run (D19); `flaky_demo` is the quarantined
fixture (it fails on odd `runs/.seq` numbers at step `flaky-assertion`).

Artifacts per run: `summary.html` + `summary.json` (verdicts, users per role,
seed profile, per-role `appLaunchMs` + `steps[]` + `failedStep` +
`failureMessage`, `quarantined`, timings incl. provisioning, redacted
firebase/provisioner config, run `seq`), `backend.log` (+ per-test slice keyed
by `X-E2E-Test-Id`), `firebase.log`, `orchestrator.log`, and per role
`video.mp4`, `app.log`, `test.log`, `screenshots/`. Tests request screenshots
with `sync.screenshot('label')`, seeding with `sync.seed('profile')`, account
resets with `sync.resetAccount()`.

## Key mechanisms

**Admin-free user pool (D23).** No Firebase admin credentials anywhere: test
users are a deterministic pool `<scope>-<role>@<email_domain>` with one
`provisioner.pool_password`; scope = test name or the manifest's
`users: {role: label}` override. The APP registers an account on first use
("Continue" = sign in, or sign up on unknown email) — the harness never calls
Firebase Auth. The backend keys data by the token's EMAIL; the harness resets
every pool account's data before and after each test. Real mode needs only
`project_id` + Web `api_key` + `pool_password` in `e2e.local.yaml`; doctor
probes key + provider with a canary sign-in.

**Fail-fast across roles (D26/R25).** The sync server keeps the FIRST failure
per run+test namespace and attaches `failed: {role, message}` to the poll
responses of `/sync/count` and the 404s of `/sync/event` + `/sync/kv`;
`barrier`/`waitForEvent`/`waitForValue` throw `PartnerFailure` (not
`SyncTimeout`) when the failing role is not the caller. `sync.failFast =
false` opts out. Covered by `harness/orchestrator/test/fail_fast_test.dart`
(a real client against a real server; it dev-depends on `test_support`, which
does not change test_support's own zero-dependency rule).

**Retention + audit memory (D24).** `runs/` (gitignored) is pruned to
`run.keep_runs` runs and `run.keep_audits` audit reports after every
run/audit (`--keep-all` skips it); audit reports snapshot their runs'
summaries so pruning never breaks them. Every audit writes
`e2e-history/<auditId>.json` (committed — one tiny file per audit, no merge
conflicts) and regenerates `e2e-history/HISTORY.md` (trend table,
regressions/improvements/suite changes since the previous audit; derived,
regenerate with `e2e history` on conflict). `e2e history` also imports
`runs/audit_*/audit.json` reports that predate their entry. Doctor warns if
the history dir is gitignored.

## Things that will bite if changed carelessly

- The orchestrator writes ONE Patrol bundle per run (into
  `<patrol.test_directory>/test_bundle.dart`, default `patrol_test/`) and
  passes `--no-generate-bundle`; the test to run is selected at compile time
  by the `E2E_TEST_ID` define. Letting patrol regenerate the bundle per
  shard makes concurrent shards run each other's tests.
- `devices.android.gpu: host`. Software Vulkan (lavapipe) drops the adb link
  during screenshots — it cost 5 of 8 runs before the fix.
- The example app signs up/in via the Firebase Auth REST API (D11/D23), so
  `E2E_AUTH_URL` must be the identitytoolkit v1 base *for the device's
  loopback* (10.0.2.2 on Android); the runner derives it from the emulator
  port per device.
- Pool accounts persist in a real project with `pool_password`; change the
  password and every existing account fails with INVALID_PASSWORD (delete
  them in the console or keep the password stable). Parallel runs against one
  real project share the pool — one run at a time.
- The backend must key data by EMAIL (from the verified token): the harness
  seeds/resets by email and never learns uids.

Known gaps: `executor.prebuild` is parsed but not implemented; Android video
is capped at 180 s by screenrecord; Android `app.log` is unfiltered logcat;
`appLaunchMs` folds build+install+launch into one number (Patrol builds
inside `patrol test`, so install is not separable without prebuild).

## Versioning and releases (D25, R24)

The harness is semver-versioned in `harness/VERSION` (inside the vendored
tree, so an integrated app carries its version; **absent == 1.0.0**), with
one `CHANGELOG.md` section per version, each carrying a **Migration**
subsection written even when it is empty.

- Work lands on `dev`: every change bumps `VERSION`, adds its changelog
  section **in the same commit**, and is tagged `v<version>`.
- `dev` → `main` is a **plain merge** — no bump, no changelog edit, no
  ritual. `main` may advance several versions at once.
- Integrators upgrade by walking every intervening version's migration in
  order (1.0 → 1.1 → 1.2 …), never a single jump.
- Maintainer procedure: `docs/releasing.md`. Integrator procedure:
  `docs/playbook/09-upgrading.md`.

## Local config

`e2e.yaml` is committed and project-neutral. Machine-local values go in
`e2e.local.yaml` (gitignored; `e2e.local.yaml.template` is the committed
schema). Precedence, lowest first:

    e2e.yaml  <  e2e.local.yaml  <  E2E_* environment variables

The overlay is deep-merged. Env overrides are an explicit allowlist
(`E2E_FIREBASE_MODE|PROJECT_ID|API_KEY|AUTH_EMULATOR_PORT`,
`E2E_POOL_PASSWORD`, `E2E_POOL_EMAIL_DOMAIN`, `E2E_ANDROID_AVD|GPU`,
`E2E_IOS_DEVICE`).

Nothing the harness needs is a secret since D23: a real project is addressed
by `project_id` + Web `api_key` (public client identifiers) and the pool
accounts share `provisioner.pool_password`. They are still project-specific,
so they live in `e2e.local.yaml`, and the redaction policy stays:
`FirebaseConfig.toRedactedJson()` is the only form allowed into
logs/artifacts, and the executor redacts `E2E_USER_PASSWORD` and
`E2E_FIREBASE_API_KEY` values from `test.log`. `e2e doctor` checks that
`e2e.local.yaml` is gitignored (works before `git init` too).

Rules:
- Default is `firebase.mode: emulator` with a `demo-` project id, so a cold
  checkout runs the full suite with nothing configured.
- Flip per command: `E2E_FIREBASE_MODE=real dart run bin/e2e.dart run`.

## Architecture rules (do not violate)

- Patrol is quarantined: only `harness/orchestrator/lib/src/executor/` and the
  app-side test files may know Patrol exists. Everything else stays
  framework-agnostic.
- `harness/test_support/` must stay zero-dependency (pure Dart, dart:io only).
- No sleep()-based coordination anywhere — sync barriers/events or
  poll-with-timeout only.
- Every subprocess call goes through `util/proc.dart` with a timeout.
- Test-only backend endpoints live under `/test/` gated by E2E_TEST_MODE=1.
- Artifacts always land in `runs/<run-id>/` per the layout in
  refined_requirements.md §R12, even for failures.

## Conventions

- `e2e.yaml` at the repo root is the single config source (devices, ports,
  timeouts).
- Android AVD name expected: `e2e_pixel` (create if missing); iOS device
  name: "iPhone 16" — both overridable in `e2e.yaml`. Check `e2e doctor`.
- `dart run --directory` is not a valid flag on Dart 3.12; `e2e.yaml` is found
  by upward search from cwd.
- `setup/` holds the macOS setup scripts (idempotent, logs to `_e2e/logs/`);
  the patch helpers they call live in `harness/tools/`.
- `_e2e/`, `m2/`–`m4/` and `implementation_plan.md` are local development
  artifacts, deliberately gitignored — do not commit them.

## Backlog

No milestone is open. Candidates, in value order: `executor.prebuild` (build
once per platform; ~30 s per role today, and it overlaps the reported race
between concurrent roles on shared Flutter build state); exercise the
playbook on an app with an existing non-Dart backend and on an SDK-based
Firebase Auth app; Android `app.log` filtering and the 180 s screenrecord
cap; the `[later]` items of refined_requirements.md §6. Open issues are
tracked on GitHub. Keep refined_requirements.md as the requirement source of
truth; record new decisions as D27+ and run
`python3 docs/decisions/regen.py`.
