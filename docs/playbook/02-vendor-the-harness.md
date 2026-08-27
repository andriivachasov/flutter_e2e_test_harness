# 02 — Vendor the harness and write `e2e.yaml`

## 2.1 Copy the harness into the target repository

The reference repository is
[`git@github.com:andriivachasov/flutter_e2e_test_harness.git`](https://github.com/andriivachasov/flutter_e2e_test_harness)
(`<REF>` below). Clone it somewhere scratch — it is a *source* you copy
files out of, not a dependency the target repo builds against, and it is
never added as a submodule or remote of the target repo.

```sh
REF=/tmp/flutter_e2e_test_harness
rm -rf "$REF"
git clone --depth 1 git@github.com:andriivachasov/flutter_e2e_test_harness.git "$REF"
# pin to a known-good tag/commit instead of the branch tip if one exists:
# git clone --depth 1 --branch <tag> git@github.com:andriivachasov/flutter_e2e_test_harness.git "$REF"
```

From `<REF>`, into the target repository root (`<TARGET>`):

```sh
mkdir -p <TARGET>/harness
cp -R <REF>/harness/orchestrator <REF>/harness/test_support <REF>/harness/tools <TARGET>/harness/
rm -rf <TARGET>/harness/orchestrator/.dart_tool <TARGET>/harness/test_support/.dart_tool
(cd <TARGET>/harness/orchestrator && dart pub get)
(cd <TARGET>/harness/test_support && dart pub get)
```
(Run these under `bash`; zsh aborts a chain on an unmatched glob.)

Also copy `<REF>/docs` into `<TARGET>/docs/e2e-harness` (or wherever fits)
so the playbook, patterns and troubleshooting guide travel with the code —
future agents (and humans) working in `<TARGET>` won't have `<REF>`
checked out. Record the commit you vendored from (`git -C <REF> rev-parse
HEAD`) in `<TARGET>`'s `e2e.yaml` as a comment, so re-vendoring later is a
diff against a known point, not a guess.

To pull in a later harness update, repeat the clone with a newer ref and
diff `<REF>/harness` against `<TARGET>/harness` before overwriting —
the target may have app-specific edits (e.g. `harness/tools` scripts
tweaked for this app's package name).

`harness/orchestrator` is the CLI; `harness/test_support` is what your
tests import (pure Dart, `dart:io` only — it never pulls Flutter or Patrol
into non-test code); `harness/tools` holds the Patrol bootstrap and the
integration checker.

## 2.2 `.gitignore`

Append (create the file if the repo has none):

```
runs/
e2e.local.yaml
secrets/*
!secrets/README.md
*service-account*.json
*firebase-adminsdk*.json
<app dir>/patrol_test/test_bundle.dart
firebase-debug.log
```

## 2.3 `e2e.yaml` at the repository root

The orchestrator finds it by walking up from the current directory; all
relative paths in it are relative to the file. Start from this and adjust
the marked lines:

```yaml
run:
  artifacts_dir: runs          # gitignored
  keep_runs: 20
  keep_audits: 10
  history_dir: e2e-history     # COMMIT this: audit memory (D24)
  capture_video: true
  quarantine_tag: quarantine

devices:
  ios:
    name: "iPhone 16"          # xcrun simctl list devices
  android:
    avd: "e2e_pixel"           # emulator -list-avds
    gpu: host                  # swangle on GPU-less machines

backend:
  dir: backend                 # <-- where the backend lives (relative to this file)
  command: ["dart", "run", "bin/server.dart"]   # <-- how to start it; [] = no backend
  health_path: /health
  start_timeout_seconds: 60
  seed_path: /test/seed
  reset_user_path: /test/reset/user
  reset_path: /test/reset

seeds:
  dir: seeds                   # <name>.json profiles; may not exist if unused

app:
  dir: .                       # <-- the Flutter app directory (often the repo root)
  tests_manifest: integration_test/e2e_tests.yaml
  ios_bundle_id: com.example.myApp          # <-- PRODUCT_BUNDLE_IDENTIFIER
  android_package: com.example.my_app       # <-- applicationId

executor:
  prebuild: false              # planned optimization, not implemented; keep false
  reset_app_data: true         # wipe app data on the device before every role
  build_timeout_seconds: 1200
  test_timeout_seconds: 900

sync:
  app_ready_timeout_seconds: 600
  step_timeout_seconds: 120

firebase:
  mode: emulator               # emulator | real | none   (decision tree, step 00)
  emulator_project_id: demo-my-app          # must start with "demo-"
  auth_emulator_port: 0        # 0 = free port per run
  cli: firebase
  # real mode: project_id + api_key go in e2e.local.yaml (public identifiers)

provisioner:
  email_domain: e2e.example.com   # pool accounts: <scope>-<role>@<email_domain>
  # pool_password: set in e2e.local.yaml (or E2E_POOL_PASSWORD) for a real project
```

Notes:
- Known-good versions (what the reference repo pins): Flutter 3.44,
  `patrol` ^4.9 in the app, `patrol_cli` 4.6.x on PATH. `pub add` may
  resolve a newer minor; that is fine as long as `patrol_cli` and `patrol`
  are both 4.x.
- The harness appends `--port <n>` to `backend.command` and expects
  `GET <health_path>` to answer 200 (step 03). With `command: []` it starts
  nothing and passes no `E2E_BACKEND_URL` to the app.
- Machine-local values go in `e2e.local.yaml` next to it (deep-merged
  over `e2e.yaml`, gitignored); `E2E_*` environment variables override
  both (`E2E_FIREBASE_MODE`, `E2E_FIREBASE_API_KEY`, `E2E_POOL_PASSWORD`,
  `E2E_ANDROID_AVD`, `E2E_IOS_DEVICE`, …). Copy
  `<REF>/e2e.local.yaml.template` for the full schema. Nothing the harness
  needs is a secret: a real project is addressed by its project id and Web
  API key only.

## 2.4 Alias

```sh
cd harness/orchestrator && alias e2e="dart run bin/e2e.dart"
```
(`dart run --directory` is not a valid flag on Dart 3.12; run from the
orchestrator directory. `e2e.yaml` is found by upward search, or pass
`--config <path>`.)

## Done when

`e2e doctor` runs and every remaining `[FAIL]` is about the app or backend
(fixed in the next steps), not about the machine or the config file.

Next: [03-backend-contract.md](03-backend-contract.md)
