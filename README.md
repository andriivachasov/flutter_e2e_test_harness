# e2e_test_harness

Flexible, reliable e2e test harness for Flutter apps (iOS + Android), designed
to be integrated into existing apps by AI agents. `refined_requirements.md`
holds the requirements and the decision log behind it. **To integrate the
harness into your own app, start at [`docs/README.md`](docs/README.md)** — the
playbook (`docs/playbook/00-overview.md` → `08-definition-of-integrated.md`),
patterns, ADRs and troubleshooting; `harness/tools/patrol_bootstrap.sh` and
`harness/tools/check_integration.sh` do the mechanical parts.

This repo ([`andriivachasov/flutter_e2e_test_harness`](https://github.com/andriivachasov/flutter_e2e_test_harness))
is the **reference repository**: a separate app repo doesn't depend on it at
build time — an agent clones it, copies `harness/` (and, for convenience,
`docs/`) into the target repo, and follows the playbook from there. See
[playbook/02-vendor-the-harness.md §2.1](docs/playbook/02-vendor-the-harness.md)
for the exact clone/copy commands. Quick version:

```sh
git clone --depth 1 https://github.com/andriivachasov/flutter_e2e_test_harness.git /tmp/flutter_e2e_test_harness
```

## Bootstrap prompt

Paste this into an AI coding agent (e.g. Claude Code) running **inside the
Flutter app repo** you want to add e2e tests to. It has everything the
agent needs to start the playbook cold.

```
Integrate the e2e test harness from
https://github.com/andriivachasov/flutter_e2e_test_harness.git into this repo.

1. Clone it to a scratch directory (e.g. /tmp/flutter_e2e_test_harness) —
   it is a reference repo you copy files out of, never a submodule,
   subtree, or remote of this repo.
2. Read <clone>/docs/README.md, then work through
   <clone>/docs/playbook/00-overview.md through
   08-definition-of-integrated.md in order. Don't skip 08 — it's the
   acceptance test.
3. Before vendoring, answer the decision tree in step 00 for this app:
   - Does it talk to a backend you can run locally? HTTP+JSON, hosted
     staging only, or no backend at all?
   - Does it sign in with Firebase Auth (email/password, other
     providers, or none)?
   - Which platforms — iOS + Android, or Android-only?
   - Is this running on a CI/GPU-less machine?
4. Vendor harness/orchestrator, harness/test_support and harness/tools
   per playbook 02, write e2e.yaml at this repo's root, wire up the app
   per steps 03-06 (test-only backend endpoints, E2E_* dart-defines,
   Patrol bootstrap, a manifest + tests for at least one smoke,
   single-user and multi-user flow).
5. Finish with step 07 (e2e doctor all-ok) and step 08
   (check_integration.sh passes, e2e run green twice in a row).

Ask me anything the decision tree needs that you can't determine from the
code (e.g. whether there's a real Firebase project to test against, or
whether CI is GPU-less) before making assumptions.
```

## Update prompt

For a repo that already has the harness and wants a newer version of it.
Paste into an agent running **inside that app repo** — it works out which
version the app is on by itself.

```
Update the vendored e2e test harness in this repo to the latest version of
https://github.com/andriivachasov/flutter_e2e_test_harness.git.

Clone it to a scratch directory and follow
<clone>/docs/playbook/09-upgrading.md. What that file expands on:

- This repo's version is in harness/VERSION. No such file means 1.0.0 —
  that is the definition, not a guess.
- Read <clone>/CHANGELOG.md and list every version between this repo's and
  <clone>/harness/VERSION. Show me that list before changing anything.
- Re-vendor harness/{orchestrator,test_support,tools,VERSION} together,
  and copy <clone>/docs over the vendored docs copy. Diff before
  overwriting — this repo may have app-specific edits inside harness/;
  tell me before dropping any.
- Apply each crossed version's Migration section IN ORDER, oldest first.
  Never jump straight to the newest: later steps assume earlier ones ran.
  Versions with an empty Migration still count as crossed.
- Verify: e2e doctor, bash harness/tools/check_integration.sh, then e2e run
  twice — both exit 0. A failure during BUILD is an environment problem
  rather than a migration one, even though it lands in test.log looking
  like a test failure.

Report the version this repo was on, the version it is on now, every
version crossed, and what you changed for each.
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
bash setup/step1_setup.sh      # toolchain, patrol_cli, platform folders, deps
bash setup/step2_ios.sh        # Patrol iOS bootstrap
bash setup/step3_devices.sh    # "iPhone 16" simulator + e2e_pixel AVD
bash setup/step4_firebase.sh   # firebase CLI (Auth emulator; no Java needed)
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

## Users, seeding, resets

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

## Self-audit

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

## License

[MIT](LICENSE). Issues and pull requests are welcome; the maintainer
procedure for cutting a version is in
[`docs/releasing.md`](docs/releasing.md).
