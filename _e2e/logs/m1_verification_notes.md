# M1 verification log — 2026-08-26

Goal: `e2e run --test cross_user_smoke` passes (iOS sim role A + Android
emulator role B, concurrent, synced via the sync server) with the full
artifact bundle in `runs/<run-id>/`.

Result: PASS, repeated (runs `2026-08-26T1144_479` and `2026-08-26T1145_266`).
Wall time per run on warm caches: ~60–90 s.

## What broke and what changed

### Step 2 (`m1/step2_ios.sh`) — `patrol build ios` failed, xcodebuild exit 65
- Error: `Multiple commands produce ... Debug-iphonesimulator/-Runner.app/PlugIns/.xctest`.
- Cause: `m1/ios_target.rb` created the `RunnerUITests` target via the
  xcodeproj gem without `PRODUCT_NAME`, so the UI-test runner app and
  bundle resolved to empty names (`-Runner.app`, `.xctest`) and collided.
- Fix: `ios_target.rb` now sets `PRODUCT_NAME = $(TARGET_NAME)` and
  re-applies all RunnerUITests build settings on every run (repairs an
  existing target instead of skipping it). Script stays idempotent.
- After the fix step 2 is green: Runner.app, RunnerUITests-Runner.app and
  the `.xctestrun` are produced.

### `e2e doctor` — three preflight failures
1. `dart run --directory harness/orchestrator ...` is not a valid `dart run`
   flag (Dart 3.12). Working form:
   `cd harness/orchestrator && dart run bin/e2e.dart <cmd>` — e2e.yaml is
   found by upward search.
2. `emulator -list-avds`: "No such file or directory". The SDK `emulator`
   binary is not on PATH even though `adb` is. Root-cause fix in the
   orchestrator: new `util/android_sdk.dart::emulatorBinary()` resolves it
   from `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, the SDK root derived from
   `adb` on PATH, or the default per-OS SDK dir; used by `doctor` and
   `AndroidDeviceManager`.
3. Devices missing: no "iPhone 16" simulator (Xcode 26.5 ships iPhone 17
   devices; the iPhone 16 *devicetype* still exists) and no `e2e_pixel`
   AVD. New idempotent `m1/step3_devices.sh` creates both
   (`simctl create` on the newest iOS runtime; `avdmanager create avd`
   with `system-images;android-35;google_apis;arm64-v8a`). Gotchas it
   handles: `avdmanager` needs Java and macOS ships a `/usr/bin/java` stub
   that *exists but does not run* — the script probes `java -version` and
   falls back to Android Studio's bundled JBR as `JAVA_HOME`.

### Run 1 — wrong emulator picked
- `AndroidDeviceManager._runningEmulatorSerial()` reused *any* running
  `emulator-*` serial; on this machine the developer's unrelated
  `kynt_android` emulator was up, so role B would have run there.
- Fix: only reuse a running emulator whose `adb emu avd name` matches the
  configured AVD; otherwise boot our own (it came up as `emulator-5556`).

### Run 2 — PASS, but iOS `video.mp4` missing with no warning
- `simctl io recordVideo` had failed silently: CoreSimulator's host
  recorder was wedged ("Host recording is already in progress") and the
  old `stop()` swallowed everything (15 s SIGINT wait → SIGKILL → no file,
  no error). A SIGKILL of recordVideo is itself what wedges the recorder
  until the simulator reboots.
- Fix in `ios_device.dart`: `startVideo` captures recordVideo's output and
  fails fast if the process exits within 2 s (so the collector logs a
  warning); `stop()` waits up to 60 s for h264 finalization and throws if
  the file is missing/empty or a SIGKILL was needed. Cleared the wedged
  state once with `simctl shutdown` + `boot`.

### Run 3 — FAIL: role A executed a test from another project
- A's patrol log showed `knots device A ...` from
  `/features/knots/knots_device_a_test.dart` (not in this repo), Total: 0;
  B then timed out at the `app-ready` barrier after 10 min.
- Cause: iOS simulators share the host loopback. Patrol's runner and app
  talk over fixed default ports 8081/8082; another project's Patrol run was
  active on the other booted simulator (iPhone 17) at the same time, so our
  RunnerUITests connected to *its* app. The same collision would exist
  between two iOS roles of one test.
- Fix: the runner allocates a unique `--test-server-port` /
  `--app-server-port` pair per role from `PortAllocator` and
  `PatrolExecutor` passes them to `patrol test` (patrol_cli 4.6 plumbs them
  to the iOS xcodebuild env and to Android `BuildConfig` via
  `-P*-server-port`). Ports are logged in `orchestrator.log`.

### Run 4 and 5 — PASS with complete artifacts, no warnings
`runs/<id>/`: backend.log, orchestrator.log, summary.{html,json},
`cross_user_smoke/{A,B}/{video.mp4, app.log, test.log, screenshots/00_start.png, screenshots/99_end.png}`.

## Known limitations carried into M2
- `executor.prebuild` in e2e.yaml is parsed but not implemented; both
  `patrol test` processes build concurrently in the same app dir. It has
  worked in every run here, but sequential prebuild is the intended design.
- Android `screenrecord --time-limit 180` caps a single recording at 3 min
  (counted from app launch since the polish below).
- Android `app.log` is unfiltered logcat (large); iOS log uses
  `process == "Runner"`.
- `patrol_cli` 4.6.1 prints an update nag (4.7.0 available); harmless.

## Post-M1 polish (same day, user request)
- Video now starts when the app under test appears on the device
  (`isAppRunning`: iOS `simctl spawn <udid> launchctl list` →
  `UIKitApplication:<bundle>[`, Android `adb shell pidof <package>`), polled
  once per second, bounded by the test timeout and cancelled when the test
  ends. Warm-run video length went from ~40 s to 11–15 s (run
  `2026-08-26T1157_677`).
- Tests take screenshots at verification points: `SyncClient.screenshot(label)`
  (zero-dep, never throws) → `POST /artifact/screenshot` on the sync server
  → `ArtifactCollector.screenshot` on the host → `screenshots/NN_label.png`.
  The smoke test shoots `home-visible`, `ping-tapped`,
  `ping-roundtrip-visible` (A), `ping-received` (B), and `failure` on any
  exception. Verified visually: both devices show "ping from A".
