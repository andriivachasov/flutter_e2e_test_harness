# 00 — Overview and decision tree

You are integrating the e2e harness into an existing Flutter app. Work
through steps 01 → 08 in order; each step says what to check before acting
and what "done" looks like. Do not skip 08 — it is the acceptance test.

## What you will end up with

- `e2e.yaml` at the repository root describing devices, backend, app and
  Firebase mode.
- `harness/` vendored into the repository (orchestrator CLI, test_support
  package, tools).
- Your app reading a handful of `E2E_*` dart-defines (backend URL, test
  ids, test user) and sending an `X-E2E-Test-Id` header.
- Patrol's native bootstrap in `android/` and `ios/` (one script does it).
- A test manifest `integration_test/e2e_tests.yaml` and Patrol tests built
  from reusable modules, wrapped in `sync.guard(...)`.
- `cd harness/orchestrator && dart run bin/e2e.dart run` green, with a run
  bundle under `runs/`.

## Decision tree — answer these first

Write the answers down; later steps branch on them.

1. **Does the app talk to a backend you can run locally?**
   - *Yes, and it is HTTP+JSON* → step 03: add the test-only endpoints and
     accept `--port`; the harness starts it per run.
   - *Yes, but it is not runnable locally (hosted staging only)* → set
     `backend.command: []` (harness starts nothing) and point the app at
     staging via its own config; seeding and account resets through the
     harness are unavailable — see step 03 "no backend".
   - *No backend at all (offline app)* → `backend.command: []`. A two-user
     test still needs shared state; the cheapest way is the starter
     backend from the reference repo (step 03) with one or two endpoints.
2. **Does the app sign in with Firebase Auth?**
   - *Yes, email/password* → `firebase.mode: emulator`; step 04 shows the
     REST and SDK variants. Test users are a fixed pool the *app* registers
     through its normal sign-up flow — the harness needs no admin access.
   - *Yes, but only social/phone providers* → keep `firebase.mode:
     emulator`, add an email/password path for tests (see
     [patterns/firebase-auth.md](../patterns/firebase-auth.md)); social
     login in e2e is out of scope.
   - *No Firebase at all* → `firebase.mode: none`. No emulator, no test
     users; `TestContext.user` stays empty.
3. **Which platforms?** Both iOS and Android are the default (macOS host).
   Android-only (Linux host) works: give every role the platform `android`
   in the manifest.
4. **Is there a CI/GPU-less machine?** Then `devices.android.gpu: swangle`
   (software renderer); the default `host` needs a real GPU driver.

## Prerequisite knowledge you can assume

- Flutter ≥ 3.x with Dart 3, Patrol 4.x (`patrol_cli` on PATH).
- Tests are `integration_test/*.dart` files using `patrolTest`.
- The harness never asks you to install Node or Java: the Firebase CLI's
  Auth emulator is self-contained.

## Ground rules (violations are the #1 cause of flaky suites)

- No `sleep()` / `Future.delayed` coordination in tests. Wait for state
  ([patterns/wait-for-state.md](../patterns/wait-for-state.md)) or use the
  sync primitives ([patterns/multi-user-sync.md](../patterns/multi-user-sync.md)).
- Every interactive widget gets a stable `Key`
  ([patterns/stable-keys.md](../patterns/stable-keys.md)).
- Test data comes from seeds and test-only endpoints, never from driving
  the UI or writing to the datastore behind the backend's back.
- Secrets never enter the repository: `e2e.local.yaml` and `secrets/` are
  gitignored; `e2e doctor` verifies that.

Next: [01-prerequisites.md](01-prerequisites.md)
