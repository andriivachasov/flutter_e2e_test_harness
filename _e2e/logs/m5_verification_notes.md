# M5 verification log — 2026-08-26

Scope (implementation_plan.md §3, M5): `docs/` tree to R22/R23 — integration
playbook for an AI agent, patterns, ADRs, troubleshooting, a
machine-checkable "definition of integrated".

DoD (the honest one): a fresh agent, given only `docs/playbook/` and a
separate vanilla Flutter app, integrates the harness and gets one
single-user + one two-user test passing without human intervention.

## Result: PASS (first exercise, one harness bug found and fixed)

Target: `/Users/a_vachasov/dev/claude_projects/e2e_playbook_dod/`
(`vanilla_app/` = `flutter create --org com.example`, no backend, no auth).
A fresh general-purpose agent received only the docs path and the target
path (rules: instructions from `docs/` only; may copy what the playbook
says to copy; must not modify the reference repo; log every gap and
source read in `PLAYBOOK_GAPS.md`).

What it built (≈16 min wall, 56 tool calls): starter backend adapted to a
room-keyed message board (auth dropped, `/test/*` + logging kept),
`BoardPage` in the app with stable keys and `setState`-on-change polling,
Patrol bootstrap via `harness/tools/patrol_bootstrap.sh` (first try, SPM
project), manifest with `smoke_board` (smoke, single-user),
`single_user_board` (single-user), `cross_user_board` (smoke, multi-user;
A iOS / B Android), modules in `integration_test/modules/board.dart`.

Runs: #1 2/3 (its own finder bug on a keyed `Text`), #2 3/3 exit 0,
#3 3/3 exit 0 — two consecutive greens; `check_integration.sh` all 29
criteria PASS. Screenshot `cross_user_board/B/screenshots/03_replied.png`
shows A's iOS message on B's Android device.

Confirmation after the upstream fixes: the target's vendored orchestrator
replaced by the fixed upstream copy → `INTEGRATION CHECK OK`, run #4
(`runs/2026-08-26T1735_915`) 3/3 exit 0.

## Gaps found by the agent → fixes (full log: `m5_playbook_gaps.md`)

| # | Kind | Finding | Fix |
|---|---|---|---|
| 1 | **harness bug** | `e2e doctor` with `firebase.mode: none` ran the service-account check (`PathNotFoundException: path = ''`) — blocked criterion 11 for every no-Firebase app | `doctor.dart`: guard skips `none`; verified `E2E_FIREBASE_MODE=none e2e doctor` all-ok |
| 2 | doc | zsh aborts the vendoring `rm -rf` chain on an unmatched glob | explicit paths + "run under bash" (02) |
| 3 | doc | `prebuild: false` in the template vs `true` in the reference `e2e.yaml` | reference set to `false` with "not implemented" comment; template annotated |
| 4 | doc | starter backend "keep the auth verifier" impossible with `mode: none`; no guidance for a namespace without users | 03: no-auth variant (drop verifier, namespace by `ctx.testId`-derived room/board) |
| 5 | doc | `AUTH_BASE_URL`/`AUTH_API_KEY` listed as always set; seed/reset-user semantics with no users unstated | 03: "only when users are provisioned"; harness never calls seed/reset-user in `none` |
| 6 | doc | 04 "done when" asked for a manual app run on shared devices | replaced by analyze + first `e2e run` |
| 7 | doc | `pub add` one-liner omitted `e2e_test_support`; no known-good versions; CocoaPods Profile warning unexplained | 05 + 02 updated |
| 8 | doc | `TestContext` fields never listed (`ctx.testId` guessed); no handoff advice for `mode: none` | 06: field table; handoff note |
| 9 | doc | keyed `Text` + `find.descendant` pitfall (its one failure) | 06 rules + patterns/stable-keys |
| 10 | doc | doctor's leftover-process check semantics vs an active run; run-dir line not documented | doctor now also lists `e2e.dart run`; 07 documents the `run … → dir` / `result:` lines |
| 11 | doc | `emulator` not on PATH but doctor fine | 01: only `adb` needs PATH |

Source reads by the agent: one (`doctor.dart` + `config.dart`, to fix #1).
Everything else was done from the docs.

## What was built for M5

- `docs/README.md`, `docs/playbook/00…08`, `docs/patterns/*` (7),
  `docs/decisions/` (ADR-001…022 generated from `refined_requirements.md`
  by `regen.py`), `docs/troubleshooting.md` — plain markdown, relative
  links (D4).
- `harness/tools/patrol_bootstrap.sh <app>` (app-agnostic Patrol native
  setup: reads package/bundle ids from the native projects), 
  `harness/tools/check_integration.sh` (29 machine-checkable criteria),
  parametrized `ios_target.rb`, copies of the gradle/podfile patchers.
- Harness: `firebase.mode: none`, `backend.command: []` (D21); doctor
  softened for missing seeds dir, optional backend/firebase checks.
- Decisions D21–D22; risk register updated.

## Known gaps carried forward
- The DoD was exercised once on one app shape (no backend, no auth). The
  "app with an existing backend in another language" and "SDK-based
  Firebase Auth" paths are documented but not exercised by an agent.
- `executor.prebuild` still unimplemented; Android video 180 s cap;
  unfiltered Android `app.log`; pooled acquire 3–7 s per role.
