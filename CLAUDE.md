# Project: e2e_test_harness

Flutter e2e test harness (iOS + Android, Patrol-based) built to be integrated
into existing apps by AI agents. Read these before doing anything:

- `refined_requirements.md` — requirements R1–R23, decisions D1–D9 (all locked)
- `implementation_plan.md` — architecture, interfaces, milestones M1–M5

## Current state (2026-08-26): M5 DONE — all milestones complete

M5 (playbook, R22/R23): `docs/` — `README.md`, `playbook/00…08`,
`patterns/`, `decisions/` (ADRs generated from refined_requirements.md by
`docs/decisions/regen.py` — edit the table there, regenerate here),
`troubleshooting.md`. Tools: `harness/tools/patrol_bootstrap.sh <app>`
(Patrol native setup for any app) and `harness/tools/check_integration.sh`
(29 machine-checkable criteria). Harness gained `firebase.mode: none` and
`backend.command: []` (D21).

M5 DoD (D22) PASSED on 2026-08-26: a fresh agent given only `docs/`
integrated the harness into a separate vanilla app at
`~/dev/claude_projects/e2e_playbook_dod/` (disposable; shares the devices)
and got smoke + single-user + two-user tests green twice; its gap log
(`_e2e/logs/m5_playbook_gaps.md`) produced one harness fix and ten doc
fixes, all upstream; confirmation run with the fixed orchestrator 3/3.
Notes: `_e2e/logs/m5_verification_notes.md`. To re-exercise: create a fresh
`flutter create` app elsewhere and spawn an agent with only `docs/`.


Full suite green in BOTH Firebase modes: `cd harness/orchestrator &&
dart run bin/e2e.dart run` → 5/5 product tests passed + the quarantined
`flaky_demo`, exit 0 (~3.5 min warm, emulator);
`E2E_FIREBASE_MODE=real dart run bin/e2e.dart run` → same against the real
test project. `cross_user_chat` takes both devices; the single-user tests
shard across them (R19a).

**2026-08-27, D24 — retention + audit memory.** `runs/` (gitignored) is
pruned to `run.keep_runs` runs and `run.keep_audits` audit reports after
every run/audit (`--keep-all` skips it); audit reports snapshot their runs'
summaries so pruning never breaks them. Every audit writes
`e2e-history/<auditId>.json` (COMMITTED — one tiny file per audit, no
merge conflicts) and regenerates `e2e-history/HISTORY.md` (trend table,
regressions/improvements/suite changes since the previous audit; derived,
regenerate with `e2e history` on conflict). `e2e history` also imports
`runs/audit_*/audit.json` reports that predate their entry. Doctor warns
if the history dir is gitignored.

**2026-08-27, D23 — admin-free user pool.** No Firebase admin credentials
anywhere: test users are a deterministic pool `<scope>-<role>@<email_domain>`
with one `provisioner.pool_password`; scope = test name or the manifest's
`users: {role: label}` override. The APP registers an account on first use
("Continue" = sign in, or sign up on unknown email) — the harness never
calls Firebase Auth. The backend keys data by the token's EMAIL; the
harness resets every pool account's data before and after each test. Real
mode needs only `project_id` + Web `api_key` + `pool_password` in
`e2e.local.yaml`; doctor probes key + provider with a canary sign-in.
Removed: service-account key, `googleapis_auth`, marker leases,
`e2e pool`, `e2e register-app`, `m3/dod_stale_lease.sh`.

M4 DoD passes: `bash m4/dod_audit.sh` — `e2e audit --runs 5` on the full
suite writes `runs/audit_<id>/audit.{json,html}`; `flaky_demo` (fails on
odd `runs/.seq` numbers at step `flaky-assertion`) is clustered as
`consistent-step`, is quarantined, and every underlying run exits 0. Notes:
`_e2e/logs/m4_verification_notes.md`.

M3 DoDs pass, as scripts (logs in `_e2e/logs/`, notes in
`_e2e/logs/m3_verification_notes.md`):
- `bash m3/dod_both_modes.sh` — all R21 tests pass in emulator AND real
  mode with the fixed pool; accounts per role in summary.json, passwords
  redacted, the `users:` override applied.
- M2 DoDs still hold: `bash m2/dod_kill_backend.sh` (now `cross_user_chat`),
  `bash m2/dod_doctor_no_xcode.sh`.

Setup from a cold checkout (idempotent, logs to `_e2e/logs/`):
`bash m1/step1_setup.sh` → `bash m1/step2_ios.sh` → `bash m1/step3_devices.sh`
→ `bash m1/step4_firebase.sh` (firebase CLI; Auth emulator only, no Java)
→ `e2e doctor` must be all-ok.

CLI: `doctor` · `run [--test <name>] [--tag <tag>]... [--keep-all]` ·
`audit --runs N [--test|--tag] [--keep-all]` · `history` · `list` ·
`devices` · `prune` (runs + audits).
Exit codes: 0 passed · 1 test failures (audit: unstable non-quarantined
test) · 2 infra.

Tests come from the manifest `example/app/integration_test/e2e_tests.yaml`
(name, target, tags, roles `ios|android|any`, optional `seed: {role:
profile}`, optional `users: {role: label}`) — not from code. Every role
gets a pool account before the body runs; tests read it from
`TestContext.user` and the app registers it on first use. Suite:
`smoke_sign_in`, `single_user_notes`, `returning_user` (register →
sign-out → sign-in asserted via the app's `auth_mode_*` banner),
`cross_user_chat` (A ios / B android, shared `chat` accounts),
`seeded_notes_reset`; modules in `integration_test/modules/`
(`launchApp`/`continueAs`/`signOut`, `addNote`/`expectNotes`,
`openChat`/`sendMessage`/`waitForMessage`). Seed profiles: `example/seeds/<name>.json` (format is
the backend's contract, see its README). Test bodies are wrapped in
`sync.guard(...)` (failure report + failure screenshot, in that order — the
report releases partner roles and the screenshot can take tens of seconds)
and mark module boundaries with `sync.step('name')` — that is where step timings (R15) and
the failing step for clustering (R14) come from. Tests tagged `quarantine`
run and are reported but never fail the run (D19); `flaky_demo` is the
quarantined fixture.

Artifacts per run: `summary.html` + `summary.json` (verdicts, users per
role, seed profile, per-role `appLaunchMs` + `steps[]` + `failedStep` +
`failureMessage`, `quarantined`, timings incl. provisioning, redacted
firebase/provisioner config, run `seq`), `backend.log` (+ per-test slice keyed by
`X-E2E-Test-Id`), `firebase.log`, `orchestrator.log`, and per role
`video.mp4`, `app.log`, `test.log`, `screenshots/`. Tests request
screenshots with `sync.screenshot('label')`, seeding with
`sync.seed('profile')`, account resets with `sync.resetAccount()`.

Fail-fast across roles (D26/R25, 1.1.0): the sync server keeps the FIRST
failure per run+test namespace and attaches `failed: {role, message}` to the
poll responses of `/sync/count` and the 404s of `/sync/event` + `/sync/kv`;
`barrier`/`waitForEvent`/`waitForValue` throw `PartnerFailure` (not
`SyncTimeout`) when the failing role is not the caller. `sync.failFast =
false` opts out. Verified by `harness/orchestrator/test/fail_fast_test.dart`
(real client against real server; it dev-depends on `test_support` for that,
which does not change test_support's own zero-dependency rule) and, on real
devices, by a temporary two-role probe — notes in
`_e2e/logs/r25_verification_notes.md`.

Things that will bite if changed carelessly:
- The orchestrator writes ONE Patrol bundle per run (into
  `<patrol.test_directory>/test_bundle.dart`, default `patrol_test/`) and
  passes `--no-generate-bundle`; the test to run is selected at compile time
  by the `E2E_TEST_ID` define. Letting patrol regenerate the bundle per
  shard makes concurrent shards run each other's tests.
- `devices.android.gpu: host`. Software Vulkan (lavapipe) drops the adb link
  during screenshots — it cost 5 of 8 runs before the fix (see
  `_e2e/logs/m2_verification_notes.md`).
- The example app signs up/in via the Firebase Auth REST API (D11/D23), so
  `E2E_AUTH_URL` must be the identitytoolkit v1 base *for the device's
  loopback* (10.0.2.2 on Android); the runner derives it from the emulator
  port per device.
- Pool accounts persist in the real project with `pool_password`; change
  the password and every existing account fails with INVALID_PASSWORD
  (delete them in the console or keep the password stable). Parallel runs
  against one real project share the pool — one run at a time.
- The backend must key data by EMAIL (from the verified token): the
  harness seeds/resets by email and never learns uids.

Known gaps carried into M5: `executor.prebuild` parsed but not implemented;
Android video capped at 180 s by screenrecord; Android `app.log` is
unfiltered logcat; `appLaunchMs` folds build+install+launch into one number (Patrol builds
inside `patrol test`, so install is not separable without prebuild).

## Versioning and releases (D25, R24)

The harness is semver-versioned in `harness/VERSION` (inside the vendored
tree, so an integrated app carries its version; **absent == 1.0.0**), with
one `CHANGELOG.md` section per version, each carrying a **Migration**
subsection written even when it is empty. Current version: **1.1.0**
(1.0.0 = baseline, everything through M5; 1.1.0 = fail-fast across roles).

- Work lands on `dev`: every change bumps `VERSION`, adds its changelog
  section **in the same commit**, and is tagged `v<version>`.
- `dev` → `main` is a **plain merge** — no bump, no changelog edit, no
  ritual. `main` may advance several versions at once.
- Integrators upgrade by walking every intervening version's migration in
  order (1.0 → 1.1 → 1.2 …), never a single jump.
- Maintainer procedure: `docs/releasing.md`. Integrator procedure:
  `docs/playbook/09-upgrading.md`.

Field-report findings from a real integration (JVM backend, existing Patrol
suite, worktrees) are filed as issues #1–#12 on the GitHub repo; #1, #2, #3
and #7 are the high-severity ones and are NOT fixed yet. #12 (fail-fast) is
done in 1.1.0; #10's `--keep-all` item is done.

## Local config (added for M3, simplified by D23)

`e2e.yaml` is committed and project-neutral. Machine-local values go in
`e2e.local.yaml` (gitignored; `e2e.local.yaml.template` is the committed
schema). Precedence, lowest first:

    e2e.yaml  <  e2e.local.yaml  <  E2E_* environment variables

The overlay is deep-merged. Env overrides are an explicit allowlist
(`E2E_FIREBASE_MODE|PROJECT_ID|API_KEY|AUTH_EMULATOR_PORT`,
`E2E_POOL_PASSWORD`, `E2E_POOL_EMAIL_DOMAIN`, `E2E_ANDROID_AVD|GPU`,
`E2E_IOS_DEVICE`).

Nothing the harness needs is a secret since D23: a real project is
addressed by `project_id` + Web `api_key` (public client identifiers) and
the pool accounts share `provisioner.pool_password`. They are still
project-specific, so they live in `e2e.local.yaml`, and the redaction
policy stays: `FirebaseConfig.toRedactedJson()` is the only form allowed
into logs/artifacts, and the executor redacts `E2E_USER_PASSWORD` and
`E2E_FIREBASE_API_KEY` values from `test.log`. `e2e doctor` checks that
`e2e.local.yaml` is gitignored (works before `git init` too). The old
`secrets/` directory and `*service-account*.json` ignore rules remain for
users who keep other credentials there; the harness no longer reads any.

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
  implementation_plan.md §R12, even for failures.

## Conventions

- e2e.yaml at repo root is the single config source (devices, ports, timeouts).
- Android AVD name expected: `e2e_pixel` (create if missing); iOS device
  name: "iPhone 16" — both overridable in e2e.yaml. Check `e2e doctor`.
- CLI: `cd harness/orchestrator && dart run bin/e2e.dart <doctor|run|list>`
  (`dart run --directory` is not a valid flag on Dart 3.12; e2e.yaml is found
  by upward search from cwd)
- `m1/` holds the setup scripts (idempotent, logs to `_e2e/logs/`); they were
  authored for a human-in-the-loop flow and can now be run/edited directly.
- `_to_delete/` is trash awaiting manual deletion; ignore it.

## Next: backlog (no milestone open)

Candidates, in value order: `executor.prebuild` (build once per platform;
~30 s per role today); exercise the playbook on an app with an existing
non-Dart backend and on an SDK-based Firebase Auth app; Android
`app.log` filtering and the 180 s screenrecord cap; the `[later]` items
of refined_requirements.md §6. Keep refined_requirements.md as the
requirement source of truth; decisions so far are D1–D22, record new ones
as D23+ and run `python3 docs/decisions/regen.py`.
