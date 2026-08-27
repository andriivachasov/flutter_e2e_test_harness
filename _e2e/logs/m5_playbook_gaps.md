# Playbook validation — gaps and notes

Target: `/Users/a_vachasov/dev/claude_projects/e2e_playbook_dod` (vanilla `flutter create` counter app, no backend, no auth).
Reference: `/Users/a_vachasov/dev/claude_projects/e2e_test_harness/docs/` (followed 00 → 08 in order).

Legend: **BUG** = harness/doc wrong, **GAP** = missing, **AMBIG** = ambiguous, **SRC** = had to read harness source, **OK** = worked as written.

## Step 00 — overview / decision tree

- OK: the decision tree covers this app exactly (no backend → starter backend; no Firebase → `firebase.mode: none`). Answers written down: 1 = no backend (starter backend), 2 = no Firebase (`mode: none`), 3 = both platforms, 4 = GPU host.

## Step 01 — prerequisites

- AMBIG (01, table row "Android SDK"): the check `emulator -list-avds` assumes `emulator` is on PATH. On this machine it is not (only `adb` is), yet `e2e doctor` finds the AVD anyway. The doc should say the harness locates `emulator` under `$ANDROID_HOME`/`~/Library/Android/sdk` and that PATH is not required, or tell the reader to add `$SDK/emulator` to PATH. Did nothing; doctor was OK.

## Step 02 — vendor the harness

- GAP (02 §2.1): the copy recipe's `rm -rf <TARGET>/harness/*/.dart_tool <TARGET>/harness/*/build` aborts under zsh (`no matches found`) when a glob has no match, and because the lines are chained the subsequent `dart pub get` never ran. Suggest `rm -rf` per directory or note "run under bash". Re-ran via `bash -c`.
- BUG (02 §2.3 + doctor): with `firebase.mode: none` (the value the decision tree prescribes for an app without Firebase) `e2e doctor` FAILs with `real Firebase project access (service account) — cannot use the service account: PathNotFoundException: Cannot open file, path = ''`. Cause (SRC — had to read `harness/orchestrator/lib/src/cli/doctor.dart` ~line 297): the guard is `if (!config.firebase.isEmulator && validate().isEmpty)`, which treats `none` like `real`. Fixed in the vendored copy by adding `&& !config.firebase.isNone`. This blocks criterion 11 of step 08 for every no-Firebase app until fixed upstream.
- AMBIG (02 §2.3 vs reference `e2e.yaml`): the template says `executor.prebuild: false`; the reference repo's own `e2e.yaml` has `prebuild: true` and troubleshooting.md says prebuild is "not implemented". Kept `false`.
- OK: `.gitignore` snippet, `e2e.yaml` template (after replacing the marked lines) and `e2e doctor` output (clear per-item messages) worked. Doctor correctly reported only the missing manifest as the remaining failure, exactly as "Done when" promises.

## Step 03 — backend contract

- AMBIG (03 §3.5, starter backend): says "keep /health, the auth verifier, the /test/* block and the logging middleware". For an app with **no auth** (`firebase.mode: none`, no ID tokens) the auth verifier cannot be kept: every `/api/*` route in the starter demands `Authorization: Bearer <Firebase ID token>`. The doc should say: with `firebase.mode: none`, drop the bearer check (delete `lib/auth.dart`, `AUTH_BASE_URL`/`AUTH_API_KEY`) and key data by something else. Did that (rooms keyed by the test id; see "Isolation" below).
- AMBIG (03 §3.3 / patterns/seeding-and-reset.md "Isolation"): "key all user data by uid... never partition by anything a production client sends" — with no users there is nothing to key by. I used a room name that the *test* chooses (`ctx.testId`) as a legitimate app feature; the doc could suggest this ("give the feature a namespace the test can pick: room, board, list name"). Guess, but worked.
- GAP (03 §3.1 table "Environment"): `AUTH_BASE_URL` / `AUTH_API_KEY` are listed as always set; unclear what is passed when `firebase.mode: none`. Irrelevant after dropping auth, but a "(only when users are provisioned)" note would help.
- GAP (03 §3.2 `/test/reset/user` and seeds): with no users there is no `uid`/`email`; the doc does not say whether the harness ever calls seed/reset-user in mode `none`. I implemented them anyway (author == uid|email) so the contract stays complete.
- OK: the "Done when" recipe (start with `--port 8099`, `/health` 200, `/test/reset` `{"ok":true}`, 403 without `E2E_TEST_MODE`) was exact and passed. The starter backend's shape (shelf, JSON log line per request with `testId`) was easy to adapt; `backend/test/api_test.dart` was rewritten for the new routes.

## Step 04 — app changes

- OK: the dart-define block, the two header lines and the polling `_refresh` "setState only when changed" advice were sufficient; `flutter analyze` clean on the first try. Keys convention from patterns/stable-keys.md applied (`home_page`, `counter_text`, `increment_button`, `open_board_button`, `board_join_page`, `name_field`, `room_field`, `join_button`, `board_page`, `board_header`, `message_list`, `message_<id>`, `board_empty`, `message_field`, `send_message_button`, `error_banner`).
- AMBIG (04 "Done when"): asks to prove the app "talks to a locally started backend" with `--dart-define=E2E_BACKEND_URL=http://127.0.0.1:8099`, but gives no command; running the app on a shared, already-booted simulator by hand is exactly what rule 4 of my brief discourages. Skipped; the first `e2e run` is the real gate (the doc itself says so in 05).

## Step 05 — Patrol bootstrap

- GAP (05): the `flutter pub add dev:patrol dev:integration_test:'{"sdk":"flutter"}'` line does not add `e2e_test_support`; only the "if pub add refuses" hand-edit block mentions it. Added it with `flutter pub add dev:e2e_test_support:'{"path":"../harness/test_support"}'` (worked; suggest adding that to the one-liner).
- AMBIG (05): the doc says `patrol: ^4.1.0`; `pub add` resolved `patrol: ^4.9.0` (same locked version as the reference app, so fine). patrol_cli prints "Update available 4.6.1 → 4.7.0"; the doc never says which patrol_cli/patrol pair is known-good. Kept what was installed.
- OK: `bash harness/tools/patrol_bootstrap.sh vanilla_app` ended with `PATROL BOOTSTRAP OK` on the first try on an SPM-created project (no `ios/Podfile` initially: the script generated it as documented). CocoaPods printed the usual "did not set the base configuration" warning; the Flutter xcconfigs already `#include?` the Pods files, so it is harmless — worth one line in "Things that bite".

## Step 06 — writing tests

- GAP (06 §6.2 / §6.4): the `TestContext` fields are never listed. The playbook uses `ctx.role`, `ctx.parties`, `ctx.user.{email,uid,password,isProvisioned}`; I needed the test id for room isolation and guessed `ctx.testId` (it exists — compiled). A short field table (`runId`, `testId`, `role`, `parties`, `backendUrl`, `syncUrl`, `user`, ...) in 6.4 would remove the guess.
- GAP (06 §6.5): the minimal two-user shape exchanges `ctx.user.email`; with `firebase.mode: none` `ctx.user` is empty, so the handoff needs another identity. Used the author name entered in the app (`user-<role>`) via `put('name/<role>')`. A sentence "with mode none, hand off whatever identifies the role in your app" would help.
- OK: manifest schema, `waitVisible` copy, module convention, `sync.*` table, the two-user shape with the 10-min first barrier and the `done` barrier — all usable verbatim. `e2e list` output matched the manifest.

## Step 07 — run, artifacts

- OK: `e2e run` worked on the first attempt from the harness's side (devices reused, backend started on a free port, sync server, one Patrol bundle, inter-test sharding: `smoke_board` went to Android while `single_user_board` went to iOS, then `cross_user_board` took both). Cold run ≈ 2.5 min, warm ≈ 2 min — faster than the 3–5 min the docs quote.
- OK: the artifact bundle matched 07's diagram exactly (`summary.html/json`, `orchestrator.log`, `backend.log` + per-test `<test>/backend.log` sliced by `X-E2E-Test-Id`, per role `video.mp4`, `app.log`, `test.log`, `screenshots/NN_label.png` plus `00_start`/`99_end`/`01_failure`). `summary.json` → `failedStep` + `failureMessage` pointed straight at my one failure (`counter`: "not visible within 15s ... counter did not show 1").
- NOTE (my own bug, not the docs'): run 1 failed `single_user_board` because I asserted `find.descendant(of: byKey('counter_text'), matching: find.text('1'))` on a keyed `Text` (descendant excludes the root). patterns/stable-keys.md shows `find.descendant(...)` for list containers only; a one-liner "for a keyed Text assert on the widget itself / `matchRoot: true`" would pre-empt the mistake. Fixed with `matchRoot: true`; runs 2 and 3 green.
- GAP (07 / troubleshooting): `e2e doctor` reported `[ok] no leftover harness processes` while an `e2e run` (backend + two `patrol test` processes) was active in another shell. Since the doc positions that check as the guard against concurrent runs on the shared devices, it should either detect an active run or the doc should say it only catches *orphans*.
- GAP (07 "exit codes"): `run` exit 1 with a clear `result: 2/3 passed, exit 1` line — fine. Not documented: where `e2e run` prints the run directory (first log line `run <id> (seq N) → <path>`); handy to mention for agents parsing output.

## Step 08 — definition of integrated

- OK: `bash harness/tools/check_integration.sh .` → all 29 criteria `[PASS]`, `INTEGRATION CHECK OK`, on the first attempt after the doctor fix above. The non-machine-checkable items hold: modules are plain typed functions; the first multi-user barrier is 10 min; a `done` barrier ends the multi-user test; no secrets exist.
- AMBIG (08 / brief): the checker's criterion 11 runs `e2e doctor`, which with `firebase.mode: none` fails without the one-line doctor fix (step 02 BUG). Every no-Firebase integration would fail acceptance on an unmodified harness.

## Summary of source reads (rule 2)

1. `harness/orchestrator/lib/src/cli/doctor.dart` + `lib/src/config.dart` — to understand and fix the `mode: none` doctor failure (BUG above). No other harness source was read; `test_support` API was used purely from the docs plus one guessed field name (`ctx.testId`).

## What worked well

- The decision tree made the two big choices (starter backend, `mode: none`) unambiguous.
- The starter backend and example tests/modules were good templates; adapting took minutes.
- `patrol_bootstrap.sh` on an SPM-generated Flutter 3.44 project: one command, zero manual Xcode/Gradle edits.
- Doctor, `e2e list`, the run log and `summary.json` gave enough to diagnose the single failure without opening any harness source.
- Repeatability: runs 2 (`runs/2026-08-26T1727_740`) and 3 (`runs/2026-08-26T1730_676`) green back-to-back, exit 0 each; the multi-user test proved a real cross-device delivery (screenshot `cross_user_board/B/screenshots/03_replied.png` shows A's message on B's Android device).
