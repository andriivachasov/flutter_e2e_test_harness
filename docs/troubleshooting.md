# Troubleshooting

Start with `e2e doctor`, then `runs/<id>/summary.html` → failing role →
"failed at step" → screenshots → `test.log` → `app.log` → `<test>/backend.log`
→ `orchestrator.log`. Every `[FAIL]` in doctor prints its own fix.

| Symptom | Cause | Fix |
|---|---|---|
| `INFRA` verdict, `backend exited unexpectedly with code …` | your backend crashed or rejected the port argument | read `backend.log`; the backend must accept the run's port (`backend.port_flag`, default `--port <n>`) and answer `GET /health` |
| `backend did not become healthy … within 60s` | wrong `backend.dir`/`command`/`port_flag`, deps not fetched, health path | run the command by hand with the port argument the harness would append (`--port 8099` by default); `dart pub get`; check `backend.health_path` |
| `ConfigError: "backend.port_flag" must contain the {port} placeholder` | a `backend.port_flag` template with no `{port}` in it | write the port as `{port}`: `"--server.port={port}"`, `["-p", "{port}"]`, `"127.0.0.1:{port}"` |
| `Auth emulator did not become ready` / `firebase: not runnable` | Firebase CLI missing or broken | `brew install firebase-cli`; `firebase --version`; or `firebase.mode: none` if the app has no Firebase |
| `refusing to start the Auth emulator for non-demo project` | `emulator_project_id` without `demo-` | rename it |
| `backend test endpoint POST /test/… failed: HTTP 403 …loopback-only` | the backend refuses `/test/*` from a non-loopback address and the orchestrator is not on the same host (backend in a container/VM, port-forwarded) | run the backend on the harness host, or map loopback into it; if it truly must be remote, keep the filter for everything else and add `backend.test_header` (playbook 03 §3.2) |
| `HTTP 403` on `/test/*` with a shared secret configured | `backend.test_header` name/value does not match what the backend compares | header names are case-insensitive, values are not; check `e2e doctor`'s `/test/* shared secret` line for the *name* (the value is never printed) and re-copy it into `e2e.local.yaml` |
| `no pool account for role A` (test fails in the auth module) | `firebase.mode: none`, or running `patrol test` by hand | run through `e2e run`; set `firebase.mode: emulator` |
| `INVALID_PASSWORD` at Continue in real mode | the pool account exists with a different password (an earlier run used another `pool_password`) | keep `provisioner.pool_password` stable per project, or delete the account in the console; one run per project at a time |
| `OPERATION_NOT_ALLOWED` / `PASSWORD_LOGIN_DISABLED` | Email/Password provider disabled in the real project | console > Authentication > Sign-in method > Email/Password (`e2e doctor` probes this) |
| `firebase.mode is "real" but api_key is unset` | no Web API key configured | console > Project settings > General > Web API Key → `e2e.local.yaml` or `E2E_FIREBASE_API_KEY` |
| Both shards ran the same test / wrong test | Patrol regenerated `patrol_test/test_bundle.dart` | never run `patrol test` manually while `e2e run` is active; the orchestrator passes `--no-generate-bundle` |
| Android role: `app log capture … ended early (exit 255)`, screenshots fail, adb "device offline" | software-GPU emulator (lavapipe) wedges adb during `screencap` | `devices.android.gpu: host` + `hw.gpu.mode=host` in the AVD (`e2e doctor` warns); `swangle` on GPU-less hosts |
| iOS: `simctl recordVideo exited immediately` | recorder busy / stale process | `pgrep -fl recordVideo`, kill leftovers; doctor's leftover-process check |
| `SyncTimeout: barrier "app-ready"` | the other role never launched (build failed, crashed) | look at the *other* role's `test.log` first; keep the first barrier at 10 min |
| `PartnerFailure: role "A" failed: …` | another role of this multi-role test failed; this role was released early on purpose (R25) | the named role is the real failure — read *its* `failedStep`, screenshots and `test.log`. This role's own artifacts show only where it was waiting |
| `not visible within 30s: … auth_page (stale session on device?)` | `reset_app_data: false` or the app restores a session from somewhere else | `executor.reset_app_data: true`; make sure the session lives in app data, not the keychain |
| Gradle: `Execution failed for task ':app:processDebugGoogleServices'` / `File google-services.json is missing` (in `<test>/<role>/test.log`) | `android/app/google-services.json` absent — it is gitignored, so a fresh clone or worktree has none | `cd <app.dir> && flutterfire configure`, or copy the file from another checkout/worktree; same for `ios/Runner/GoogleService-Info.plist` (`e2e doctor` now fails on both before a run starts) |
| `patrol test` fails with Gradle/Xcode errors on first run | bootstrap incomplete | `bash harness/tools/patrol_bootstrap.sh <app>` again; `flutter clean`; `pod install` |
| iOS build: `RunnerUITests` missing / scheme error | xcodeproj target not added | re-run the bootstrap (it repairs settings); check `ios/Runner.xcodeproj` contains `RunnerUITests` |
| iOS build: `xcodebuild: error: Could not resolve package dependencies: the package at '…/ios/Flutter/ephemeral/Packages/.packages/patrol-<v>' cannot be accessed` | the app used to wire Patrol as a **local Swift package**; the bootstrap disables SPM, so Flutter no longer generates that path but `Runner.xcodeproj` still points at it | re-run `bash harness/tools/patrol_bootstrap.sh <app dir>` (step `ios: stale SwiftPM patrol package`), or alone: `cd <app>/ios && ruby <harness>/tools/ios_spm_cleanup.rb`; `e2e doctor` warns about it |
| `e2e list`: `test "x" target does not exist` | wrong relative path | targets are relative to `app.dir` |
| `seed profile "x" not found` | file missing under `seeds.dir` | create `seeds/x.json` |
| Audit says `consistent-step` for a real test | same step fails with the same message every time | that is a product bug (or a real race) — fix the app; do not quarantine |
| Runs are slow (~3 min warm) | Patrol builds inside each `patrol test`; ~30 s build+install per role | expected; `executor.prebuild` is the planned optimization (not implemented) |
| Video shorter than the test (Android) | `screenrecord` caps at 180 s | known limitation; screenshots cover the rest |

Leftover processes after an interrupted run: `e2e doctor` lists them
(backend, `simctl recordVideo`, `patrol test`, `emulators:start`); kill
them before the next run.
