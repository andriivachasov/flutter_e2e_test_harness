# E2E Test Harness — Implementation Plan

**Status:** v1 for review · 2026-08-26
**Inputs:** `refined_requirements.md` v1.1 (decisions D1–D9, requirements R1–R23)

---

## 1. Repo layout

Monorepo. The harness is separable from the example by construction — the playbook's integration story depends on that boundary being clean.

```
e2e_test_harness/
├── harness/                        # reusable — what gets integrated into target apps
│   ├── orchestrator/               # Dart CLI package: `e2e` command
│   │   └── lib/src/
│   │       ├── cli/                # run, doctor, audit, devices, prune
│   │       ├── devices/            # DeviceManager: boot/install/capture (simctl, adb)
│   │       ├── executor/           # PatrolExecutor — the ONLY Patrol-aware module (D5 insurance)
│   │       ├── env/                # backend + Firebase emulator lifecycle, port allocator
│   │       ├── users/              # UserProvisioner: ephemeral | pooled
│   │       ├── seed/               # SeedLoader: fixtures → backend seed endpoint
│   │       ├── sync/               # SyncServer (orchestrator side)
│   │       ├── artifacts/          # ArtifactCollector, summary.html/json rendering
│   │       └── audit/              # reliability + performance audits (R14/R15)
│   └── test_support/               # Dart package imported by app-side tests
│       └── lib/src/
│           ├── sync_client.dart    # barrier/event/kv client
│           ├── context.dart        # TestContext: role, user, backend URL, run id
│           └── module.dart         # test-module conventions and helpers
├── example/
│   ├── app/                        # Flutter app (Firebase Auth via emulator, polling chat)
│   │   └── integration_test/      # Patrol tests + app-specific modules (signIn, sendMessage…)
│   ├── backend/                    # Dart shelf: API + test-only endpoints (seed, reset, health)
│   └── seeds/                      # named seed profiles (JSON)
├── docs/                           # playbook — plain markdown, Obsidian-compatible (D4)
│   ├── playbook/                   # step-by-step integration guide for AI agents
│   ├── decisions/                  # ADRs (start by importing D1–D9)
│   ├── patterns/                   # wait-for-state, multi-user sync, seeding, resets
│   └── troubleshooting.md
├── runs/                           # artifacts (gitignored, keep-last-20 per D9)
└── e2e.yaml                        # harness config: devices, ports, retention, provisioner mode
```

Two hard rules the layout encodes:

1. **Patrol is quarantined** in `executor/` and in the test files themselves. Nothing else imports it. Fallback to raw `integration_test` (per §3.4 of requirements) rewrites one directory.
2. **`test_support` has no orchestrator dependency** — it's what a target app actually imports, so it must stay lightweight and free of device/CLI concerns.

## 2. Core interfaces

Signatures are the contract; implementations may grow, shapes should not.

```dart
// users/ — R10, D2, D6
abstract class UserProvisioner {
  Future<TestUser> acquire(UserSpec spec);       // spec: fresh | seeded profile name
  Future<void> release(TestUser user);           // cleanup / lease return
  Future<void> reset(TestUser user);             // account-level reset (R9b)
}
// EphemeralProvisioner: Firebase Auth emulator REST. Pool state: none.
// PooledProvisioner: dedicated test project (D6); lease file/collection with TTL
//   for stale-lease recovery; per-lease data cleanup on release.

// sync/ + sync_client — R18. HTTP long-poll (keeps it dependency-free).
abstract class SyncClient {
  Future<void> barrier(String name, {required int parties, Duration timeout});
  Future<void> emit(String event, [Map<String, Object?> data]);
  Future<Map<String, Object?>> waitFor(String event, {Duration timeout});
  Future<void> put(String key, Object? value);   // cross-device data handoff
  Future<T?> get<T>(String key);                 //   (e.g. UserB reads UserA's chat id)
}

// executor/ — the Patrol quarantine. R4, R17, R19.
abstract class TestExecutor {
  Future<TestResult> run(TestSpec spec, DeviceHandle device, TestContext ctx);
}
// TestContext reaches the app-side test via --dart-define:
//   runId, testId, role, backendUrl (platform-resolved: 10.0.2.2 vs localhost),
//   syncUrl, user credentials.

// artifacts/ — R12, R13
abstract class ArtifactCollector {
  Future<void> beginTest(TestId id, List<DeviceHandle> devices); // start video + log taps
  Future<void> screenshot(TestId id, DeviceHandle d, String label);
  Future<TestArtifacts> endTest(TestId id, TestStatus status);   // stop, slice backend log by runId
}
```

**Test module convention (R7/R8):** a module is a plain Dart function `Future<SignedInSession> signIn(PatrolTester $, TestContext ctx)` — typed input/output, no globals, declared preconditions via the test's `TestSpec` (required seed profile, user count, tags). The orchestrator satisfies preconditions before the test body runs; modules never provision users or seed data themselves.

**CLI surface (R3/R4/R5):**
`e2e doctor` · `e2e run [--test <name> | --tag <tag>] [--keep-all]` · `e2e audit --runs N [--test|--tag]` · `e2e devices` · `e2e prune`

## 3. Milestones

Ordered by risk, not by layer. Each has a Definition of Done that is a runnable command, not a judgment call.

### M1 — Risk burn-down: the two-device slice *(the absorbed spike; nothing else starts until this passes)*
Minimal app (button that POSTs, screen that polls), minimal backend (2 endpoints + health), orchestrator boots 1 iOS simulator + 1 Android emulator (D7), installs, runs one Patrol test per device with roles A/B, sync barrier + kv handoff, cross-user assertion via polling, video + screenshots + app/test/backend logs land in the `runs/` tree.
**DoD:** `e2e run --test cross_user_smoke` passes from a cold checkout on macOS; artifacts complete for both devices. **Explicit gate:** if Patrol is unworkable here, decide fallback now (rewrite `executor/` on raw `integration_test`) — this is the only milestone where that decision is cheap.

### M2 — Harness core
Full CLI (single/tag/all), `doctor` with actionable errors, timeouts on every external operation (R6), `summary.html` + `summary.json`, run-id log correlation end-to-end (R13), port allocator, retention/prune (D9), inter-test sharding across the two devices for single-user tests (R19a).
**DoD:** killing the backend mid-test yields a failed run with a complete artifact bundle and non-zero exit — no hang; `doctor` on a machine without Xcode says exactly what to install.

### M3 — Auth, users, state, and the real example
Firebase Auth emulator wired into app + orchestrator lifecycle. `EphemeralProvisioner`; `PooledProvisioner` verified against the dedicated test project (D6). Seeding endpoints + named profiles (R16); both reset flows (R9). Example app grows to spec (R20): sign-in, single-user feature, polling chat. Test suite to spec (R21) built from modules.
**DoD:** all R21 tests pass under both provisioner modes (`e2e run` with `provisioner: ephemeral|pooled` in `e2e.yaml`); a killed pooled run leaves no stuck lease (TTL recovery proven by test).

### M4 — Self-audit
`e2e audit`: N-run execution, per-test pass rate, p50/p95 durations, failure clustering by failing step, flake-quarantine tag honored by `run` (R14); timing breakdown of device boot/install/module phases (R15).
**DoD:** `e2e audit --runs 5` on the full suite emits a report; a deliberately flaky test (injected) is correctly clustered and quarantined.

### M5 — Playbook
`docs/` tree to R22/R23: integration guide, patterns, ADRs, troubleshooting, machine-checkable "definition of integrated" checklist.
**DoD — the honest one:** an AI agent, given only `docs/playbook/` and a *separate vanilla Flutter app* (created fresh, not the example), integrates the harness and gets one single-user + one two-user test passing without human intervention. Playbook gaps found become fixes, and the exercise repeats until it passes.

Effort shape (relative): M1 ≈ M3 > M2 > M5 > M4. M1 and M3 carry the unknowns; M4 is mostly bookkeeping over data M2 already collects.

## 4. Cross-cutting build rules

In force from the first commit: no `sleep()`-based coordination anywhere — poll-with-timeout or sync primitives only (R18); every subprocess call goes through one wrapper that enforces timeout + captures output into the artifact tree (R6); test-only backend endpoints live under `/test/` and are enabled by an env flag the example's prod entrypoint never sets (R16); stable widget keys from day one in the example app, following the convention the playbook mandates (R23); loopback resolution (`10.0.2.2` vs `localhost`) lives in exactly one place (`TestContext` construction).

## 5. Risk register

| Risk | Exposure | Mitigation |
|---|---|---|
| Patrol instability (known community reports) | M1, ongoing | M1 gate + `executor/` quarantine; pinned versions; audit (M4) tracks flake rate over time |
| Video/log capture flakiness (`simctl recordVideo`, `logcat`) | M1–M2 | Capture failures degrade the artifact bundle, never fail the test; `doctor` verifies capture works |
| Software-GPU (lavapipe) Android emulator drops the adb link when `screencap` runs against a compositing app — killed 5/8 runs | M2, diagnosed and fixed | `devices.android.gpu: host` (passed as `-gpu` at boot) + `hw.gpu.mode=host` written into the AVD by `m1/step3_devices.sh`: 0/8 failures. Doctor warns on `auto`. Secondary hardening: per-device graphics lock, bounded screenshot retry, warning when a log capture dies early (notes: `_e2e/logs/m2_verification_notes.md`) |
| Firebase Auth emulator vs Patrol native auth flows | M3, resolved | Example uses email/password through the Auth REST API (D11) — no native browser hop, no native Firebase SDK in the build; social login documented as a playbook pattern, out of example scope |
| Pooled leases racing across machines | M3, measured | Real Firebase Auth accepts *simultaneous* duplicate-email creates (6/6 measured; sequential ones are rejected). `PooledProvisioner` serializes acquires in-process and settles + yields to an older rival marker after creating its own (D12); the TTL bounds any residual damage; the M4 audit would surface it as sign-in failures |
| Port collisions / zombie processes under parallel runs | M2–M4 | Central port allocator; PID tracking + cleanup on start; `doctor` detects leftovers |
| iOS simulator boot time makes audit runs slow | M4 | Reuse booted devices across tests within a run; boot time reported separately by R15 so it doesn't pollute test timings |
| Playbook overfits to the example app | M5, exercised | The vanilla-app DoD (D22) ran 2026-08-26: a fresh agent integrated the harness into a `flutter create` app (no backend, no auth → starter backend + `firebase.mode: none`) and got smoke + single-user + two-user tests green twice; it found one harness bug and ten doc gaps, all fixed upstream |

## 6. Out of scope (unchanged from requirements §8)

CI pipeline maintenance, device farms, physical devices, web/desktop, load testing, store build lanes. The `[later]` items from requirements §6 stay later.
