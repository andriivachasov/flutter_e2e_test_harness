# M2 verification log — 2026-08-26

Scope (implementation_plan.md §3, M2): full CLI, doctor with actionable
errors, timeouts everywhere (R6), summary.html/json, run-id correlation
(R13), port allocator, retention/prune (D9), inter-test sharding (R19a).

DoD status:
- `m2/dod_kill_backend.sh` — PASS: SIGKILL of the backend while both apps
  are on screen → run aborts, exit 2, 76 s after the kill, complete bundle
  (video/app.log/test.log/screenshots for both roles, per-test backend.log,
  summary with `infraError: backend exited unexpectedly with code -9`).
  Log: `_e2e/logs/m2_dod_kill_backend.log`.
- `m2/dod_doctor_no_xcode.sh` — PASS: with `xcrun` shadowed, doctor exits 1,
  prints `[FAIL] xcrun simctl (Xcode)` with the exact install steps
  (App Store → xcode-select → runFirstLaunch → downloadPlatform), skips the
  simulator check, still runs the Android checks.
  Log: `_e2e/logs/m2_dod_doctor_no_xcode.log`.
- Full suite (`e2e run`, 3 tests) passes with sharding: `cross_user_smoke`
  takes both devices, then `single_user_ping` (iOS) and `single_user_home`
  (Android) run concurrently. ~85 s warm.

## What was built

- **Test manifest** `example/app/integration_test/e2e_tests.yaml` replaces
  the hardcoded registry: name, target, tags, roles (`ios|android|any`).
  `e2e list` / `e2e run --test|--tag` read it; doctor validates it.
- **Scheduler** (`run/runner.dart`): greedy assignment over the device pool;
  a test starts as soon as each role has a free device; `any` roles take
  whatever is free; fixed-platform roles wait for theirs. Tests needing an
  unavailable platform (iOS on Linux) get an INFRA outcome, not a hang.
- **Backend death → abort**: `BackendProcess.unexpectedExit` completes an
  abort future; `runProc(abort:)` SIGTERMs (then SIGKILLs) every running
  `patrol test`; pending tests get INFRA outcomes; exit 2.
- **Per-test backend.log** slice by `"testId":"<name>"` (the app sends
  `X-E2E-Test-Id`, the backend echoes it per request line).
- **CLI**: `run [--test] [--tag]... [--keep-all]`, `list`, `devices`,
  `prune`, `doctor`. Exit codes 0/1/2 documented in `--help`.
- **Doctor**: exact Xcode instructions, cocoapods check, leftover-process
  detection (backend / recordVideo / patrol test), manifest validation.
- **Summary**: per-test cards with tags, verdict (PASS/FAIL/TIMEOUT/
  ABORTED/INFRA), per-role links, screenshot gallery; summary.json carries
  verdicts, artifact paths, counts, timings (backend start, device boot).
- **R6 audit**: Android screenshot moved from an unbounded `Process.run` to
  bounded `screencap`+`pull`; all remaining external calls go through
  `runProc`/`runProcChecked` or are long-lived captures with bounded stops.

## What broke and what changed

### Concurrent shards ran the wrong test
`patrol test --target X` regenerates a single shared bundle file per
invocation; two shards building different targets in one app dir
overwrote each other's bundle, so both ran whichever was written last.
Fix (Patrol-quarantined, `executor/patrol_executor.dart`): the orchestrator
writes ONE stable bundle per run covering every manifest test, each group
guarded by `if (E2E_TEST_ID == '<name>')` (a compile-time dart-define every
shard already gets), and passes `--no-generate-bundle`. Identical file for
all shards, exactly one test per build.
Gotcha found on the way: patrol_cli 4.6's bundle lives in
`<patrol.test_directory>/test_bundle.dart` and the default directory is
`patrol_test/`, not `integration_test/` — a bundle written elsewhere is
silently ignored. The generator reads the pubspec setting.

### Shared backend state across concurrent tests (D10)
The example backend now partitions data by `X-E2E-Test-Id` in test mode;
`/test/reset` with the header clears one partition. Recorded as D10 in
refined_requirements.md.

### Android adb link drops (intermittent)
See the section below — investigated with a reconnecting logcat trap and
adb/emulator tracing.

## Android adb link drops — root cause and fix

Symptom: intermittently role B failed with `app log capture ... ended early
(exit 255)` plus `screencap/pull ... exit 1`, turning the run red. iOS was
never affected. Measured base rate on the original AVD: **5 of 8**
`cross_user_smoke` runs.

Evidence gathered: a reconnecting logcat trap across drops, host
`ADB_TRACE=adb,transport`, and emulator `-verbose`. Every captured drop has
the same shape — an `adb shell screencap` (shell uid 2000, `Gralloc4:
mapper 4.x is not supported`, allocator missing from the VINTF manifest)
runs while the app is compositing its first frames, then the host adb logs
`emulator-5556: connection terminated: read failed` and adbd drops the
socket, killing the instrumentation along with the capture.

Hypotheses tested, in order:
1. *Concurrent graphics grabs* (screencap racing screenrecord start).
   Added a per-device graphics mutex → **5/8 still failed**. Not the cause,
   but the lock is correct and was kept.
2. *screenrecord itself*. Ran with `run.capture_video: false` →
   **2/6 still failed**. Not the cause.
3. *Emulator GPU backend*. The AVD ran software Vulkan
   (`hw.gpu.enabled=no`, runtime `hw.gpu.mode=lavapipe`). Rebooted the same
   AVD with `-gpu host` (`vulkan_mode_selected:host gles_mode_selected:host`)
   → **0 of 8 runs failed**, video on. **This is the cause.**

Fix (scripted, not manual):
- `e2e.yaml` gains `devices.android.gpu` (default `host`); the orchestrator
  passes `-gpu <mode>` when it boots an emulator.
- `m1/step3_devices.sh` writes `hw.gpu.enabled=yes` / `hw.gpu.mode=host`
  into the AVD's `config.ini`, so an emulator started by hand or by Android
  Studio gets it too. Idempotent.
- `e2e doctor` warns when the configured AVD has `auto`/missing GPU mode.
- Kept from the earlier hypotheses: per-device graphics mutex, one bounded
  retry on Android screenshots, and a warning when a device log capture dies
  before its test ends (the signal that made this diagnosable at all).

New knob: `run.capture_video` (default true) turns screen recording off
without touching screenshots or logs.

### Caveats this fix creates (carry to M4/M5)
`host` is the right default for local macOS runs, not a universal one:

1. **CI must override it.** `-gpu host` passes only when the emulator's
   `hasSufficientHwGpu` check finds a usable GPU driver. A GPU-less runner
   needs `devices.android.gpu: swangle` (or `swiftshader`) — one line in
   e2e.yaml, no code change. Note the constraint is GPU availability, *not*
   headlessness: `-gpu host -no-window` boots and screencaps fine on this
   Mac (verified 2026-08-26). Also note this emulator build's modes are
   `auto | host | software | lavapipe | swiftshader | swangle`; the older
   `swiftshader_indirect` name is gone.
2. **Screenshots are now host-GPU-dependent**, so pixel output can differ
   between machines. Harmless while screenshots are diagnostic, but the
   `[later]` visual-regression/golden-screenshot idea would need a pinned
   *software* renderer to be portable — software rendering is deterministic,
   which is exactly why CI guidance usually prefers it.
3. `hw.gpu.mode=host` in `~/.android/avd/e2e_pixel.avd/config.ini` is a
   machine-level side effect: it applies to Android Studio and any manual
   `emulator -avd e2e_pixel` too. That is deliberate — the `-gpu` flag only
   covers emulators the orchestrator boots itself; the harness reuses an
   already-running emulator, where only the config file applies.

## Final verification (2026-08-26)
- `dod_kill_backend.sh`: PASS — exit 2, 85 s after the kill, bundle complete.
- `dod_doctor_no_xcode.sh`: PASS.
- `e2e run` (full suite) twice: 3/3 passed, exit 0, zero warnings.
- Unit tests: orchestrator 10 passed, backend 6 passed. Analyze clean on
  orchestrator, test_support, and the example app.

## Local config / secrets mechanism (M3 prep, 2026-08-26)
Built before M3 so real Firebase credentials never enter the repository:
- `HarnessConfig.load` now layers `e2e.yaml` < `e2e.local.yaml` (gitignored,
  deep-merged) < `E2E_*` env overrides (explicit allowlist), and records the
  sources it used.
- New `firebase` (mode/project_id/api_key/service_account_key_path/
  auth_emulator_port) and `provisioner` (mode/pool_size/lease_ttl_seconds)
  sections. Defaults are emulator-only with a `demo-` project id, so a cold
  checkout needs no credentials.
- `FirebaseConfig.validate()` catches incoherent setups (emulator mode with
  a non-demo project; real mode missing key/api_key/service account; pooled
  provisioner on emulator mode). `toRedactedJson()` is the only printable
  form — verified by a test that greps for the secret values.
- `.gitignore`: `e2e.local.yaml`, `secrets/*` (README kept),
  `*service-account*.json`, `.env*`, plus the per-project Firebase files
  (`firebase_options.dart`, `google-services.json`,
  `GoogleService-Info.plist`, `firebase_app_id_file.json`).
- `e2e doctor` prints config sources + redacted firebase summary, validates
  the merged config, and fails if a present secret file is not ignored —
  including before `git init`, where it requires the `.gitignore` rule to
  exist already. Both the positive and negative paths were exercised.
- 7 new unit tests (17 total in the orchestrator).

### Real project wired in (2026-08-26)
Test project `firebase-spike-257111` (D6) configured locally:
- Service-account JSON moved from the repo root into
  `secrets/firebase-service-account.json` (mode 600). It arrived named
  `*-firebase-adminsdk-*.json`, which did **not** match the existing
  `*service-account*.json` rule — `.gitignore` gained `*firebase-adminsdk*.json`
  and `*-adminsdk-*.json`.
- Credential verified live, not just present: self-signed JWT -> OAuth token
  -> `identitytoolkit.googleapis.com/v1/projects/<id>/accounts:batchGet`
  returned HTTP 200. The key authenticates and has Auth admin access.
- `e2e.local.yaml` created with the real project + key path but
  `mode: emulator`, so day-to-day runs stay on the emulator; the real project
  is one env flip away.

Model correction this exposed: `api_key` had been treated as required in
real mode. It is not — the Admin SDK (service account) provisions users
without it, and the Web API key only matters for the *app* signing in. It is
now a warning, `emulator_project_id` and `project_id` are separate keys, and
`canProvisionUsers` / `canSignInFromApp` express the two capabilities.

Also replaced the pre-`git init` ignore check: it had been a substring match,
which silently failed on glob rules (`secrets/*`, `*service-account*.json`)
and produced a false "NOT ignored" on a properly ignored key. There is now a
real `.gitignore` matcher (`util/gitignore.dart`, 6 tests) covering globs,
`**`, anchored paths, directory rules and `!` negation.
