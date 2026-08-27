# E2E Test Harness for Flutter — Refined Requirements

**Status:** v1.1 — all open questions resolved · 2026-08-26
**Supersedes:** `initial_requirements.txt`

---

## 1. Purpose

Build a flexible, reliable end-to-end test harness for Flutter applications (Android + iOS), delivered as:

1. **A reference repository** — a working example app + Dart backend + harness, with passing e2e tests including a multi-user interaction test. The repo proves every claim the docs make.
2. **An integration playbook** — structured markdown instructions written for an **AI agent** (not a human) to integrate the harness into an arbitrary existing Flutter app. The playbook must be explicit about decision points and preconditions ("if the target app already has X, do Y; otherwise Z").

The playbook is only trusted because the reference repo verifies it. Both are first-class deliverables.

---

## 2. Decisions made (2026-08-26)

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Example backend stack | **Dart (shelf)** | Single toolchain across app, tests, orchestrator, backend. AI agents integrating the harness need only Flutter/Dart installed. |
| D2 | Firebase scope | **Emulator-first, design for real** | Local runs use Firebase Emulator Suite (Auth). The user-provisioning layer is abstracted so the same tests can later run against a real/staging Firebase project. Both strategies (fresh-user and pooled) get implemented, not just documented. |
| D3 | Deliverable shape | **Repo + playbook, both first-class** | See §1. |
| D4 | Knowledge base tooling | **Plain markdown in-repo, Obsidian-compatible** | The docs are consumed by AI agents inside a repo; versioning with code beats an external app. Use plain relative links (no wikilinks) so Obsidian can open the folder as a vault for human browsing — zero dependency, full compatibility. Obsidian is *not* a build/runtime dependency. |
| D5 | UI automation framework | **Patrol, committed (no pre-build spike)** | See §3. Consequence: the isolation layer (§3.3) is mandatory, not optional, and the two-device slice is built as the *first* implementation milestone so any Patrol instability surfaces in week one, not mid-build. |
| D6 | Real-Firebase environment | **Dedicated test-only Firebase project** | Pool/cleanup bugs have zero blast radius. Credentials: service-account key file, path via env var, gitignored. Pooled provisioner is fully verifiable against it. |
| D7 | Default device matrix | **1 recent iOS simulator + 1 recent Android emulator** (configurable) | Latest stable iOS + recent API level (34/35). Older-OS coverage is config, not v1 scope. |
| D8 | Example delivery mechanism | **Polling** | Stays inside the http/1+json constraint; playbook documents the same wait-for-state pattern for websockets/SSE/push. |
| D9 | Artifact retention | **Keep last 20 runs, `--keep-all` flag** (default asserted, not asked) | Conventional default; trivially configurable. |
| D11 | App-side Firebase sign-in (2026-08-26, M3) | **The example app signs in through the Firebase Auth REST API (Identity Toolkit `accounts:signInWithPassword`), not the native `firebase_auth` SDK.** The base URL (`E2E_AUTH_URL`) and Web API key (`E2E_FIREBASE_API_KEY`) arrive as dart-defines, so one code path serves the emulator and a real project | No per-platform Firebase config files (`GoogleService-Info.plist`, `google-services.json`), no Firebase pods/gradle plugins in the build, and nothing to keep out of git. The playbook documents the SDK variant (`FirebaseAuth.instance.useAuthEmulator(host, port)` + `FirebaseOptions` from defines) for apps that already use it. |
| D12 | Pooled-lease storage (2026-08-26, M3) — **superseded by D23** | **A lease on pool slot N is a *marker* Auth user `lease.<prefix>N@<domain>`.** Firebase Auth rejects a create for an existing email (`EMAIL_EXISTS`), so non-overlapping contenders exclude each other across processes and machines. *Measured caveat (2026-08-26, real project): creates in flight at the same instant can all succeed — the uniqueness check is read-then-write — so after creating its marker a contender settles (1.5 s), re-reads all accounts with that email and yields unless its marker is the oldest (ties: lowest uid); losers delete theirs. Acquires within one process are serialized outright.* The marker's `displayName` carries `{owner, expiresAt, host, pid}`; holders heartbeat it; anyone may reclaim a marker whose `expiresAt` has passed. On every acquire the pool account gets a fresh password and its sessions are revoked | Concurrency-safe leasing with stale-lease recovery (R10) using only the Auth API the harness already needs — no Firestore, no lock files, no extra datastore to provision or clean. Leases are visible in the Firebase console and via `e2e pool`. Residual risk: two *different machines* creating the same marker within the same ~100 ms and both reading before the other's write is visible; the TTL bounds the damage and the audit (M4) would show it as a sign-in failure. |
| D13 | Backend token verification (2026-08-26, M3) | **The example backend verifies bearer ID tokens by calling Identity Toolkit `accounts:lookup` with the token** (cached per token), against the emulator or the real project depending on `AUTH_BASE_URL` | One code path, zero JWT/RSA code in a Dart example. A production backend verifies signatures locally (Firebase Admin SDK); the playbook documents that swap — the harness contract (bearer token in, uid out) is unchanged. |
| D14 | Data isolation, revised (2026-08-26, M3; amends D10) | **Isolation between concurrently sharded tests now comes from per-test users: every role gets its own Firebase Auth user and the backend keys all data by that user.** The `X-E2E-Test-Id` header is kept for log correlation only (R13) | This is the pattern real apps already have; the header partition was an M2 stop-gap for an unauthenticated app. |
| D15 | Auth emulator lifecycle (2026-08-26, M3) | **One Auth emulator per run, started by the orchestrator through the `firebase` CLI with a per-run `firebase.json` whose ports (auth, hub, logging) come from the port allocator; only the Auth emulator is started.** Installed via `brew install firebase-cli` (`m1/step4_firebase.sh`) | Parallel runs never collide (R19); the Auth emulator lives inside the CLI, so no Java runtime is needed; `firebase.log` lands in the run's artifact bundle (R12). |
| D16 | App-level reset (2026-08-26, M3) | **R9a = Android `pm clear <package>` / iOS `simctl uninstall <bundle>` before every test role (`executor.reset_app_data: true`); Patrol reinstalls.** The example app persists its session on device so a leaked session would be visible (every test starts by asserting the sign-in page) | Cheapest complete wipe on each platform; the persisted session turns "reset happened" into an assertion instead of a belief. |
| D17 | Web API key handling (2026-08-26, M3) — **superseded by D23** | **`firebase.api_key` is optional in real mode: the orchestrator discovers the project's Web API key from any registered app via the Firebase Management API; `e2e register-app` registers a Web app named `e2e-harness` once if the project has none** | The key is a public client identifier, not a secret, and the service account can read it — one less value to copy by hand into `e2e.local.yaml`. |
| D18 | Step and failure reporting (2026-08-26, M4) | **Tests mark module boundaries with `sync.step('name')` and wrap their body in `sync.guard(...)`, which on failure takes the failure screenshot and reports the failure (step + message) to the orchestrator.** The orchestrator times steps (`summary.json` → `roles[].steps`) and records `failedStep` / `failureMessage` | One convention gives both R15 per-module durations and R14 failing-step clustering without parsing Patrol's log; modules stay plain functions (R7). Reporting is fire-and-forget and never fails a test. |
| D19 | Flake quarantine semantics (2026-08-26, M4) | **A test tagged with `run.quarantine_tag` (default `quarantine`) runs and is reported (`QUARANTINED FAIL`, a run warning, `counts.quarantinedFailed`) but does not affect the exit code.** `e2e audit` suggests candidates (`0 < pass rate < 1`, not yet tagged); adding the tag is a manifest edit, never automatic | "Known-flaky tests don't block runs but stay visible" (R14) literally; tag-based so the quarantine list lives with the tests and in version control. |
| D20 | Audit output and verdicts (2026-08-26, M4) | **`e2e audit --runs N` runs the selection N times (each a full run with its own bundle) and writes `runs/audit_<id>/audit.json` + `audit.html`.** Per test: pass rate, p50/p95/min/max duration, provisioning and launch p50, per-step p50/p95, failure clusters keyed by (failing step, number-normalized message). Verdicts: `stable`, `consistent-step` (top cluster ≥ 75 % of ≥ 2 failures → likely product bug), `scattered` (→ likely flaky infra), `single-failure` (inconclusive), `infra`. Exit 0 iff every non-quarantined test is `stable` | Implements R14's clustering rule as stated; every number links back to a run bundle. A deterministic fixture (`flaky_demo`, fails on odd `runs/.seq` numbers, quarantined) keeps the DoD reproducible instead of probabilistic. |
| D21 | Optional Firebase and backend (2026-08-26, M5) | **`firebase.mode: none` (no emulator, no provisioned users, `TestContext.user` empty) and `backend.command: []` (harness starts no backend, passes no `E2E_BACKEND_URL`; seeding/account resets unavailable) are first-class configurations.** Manifest `seed:` entries are rejected at run start in either | The playbook must be honest for arbitrary apps: a vanilla app has neither Firebase nor a backend, and the harness (devices, sync, artifacts, audit) is still useful for it. Verified by the M5 DoD on a vanilla app with `mode: none` + a starter backend. |
| D22 | Playbook verification protocol (2026-08-26, M5) | **The playbook's DoD is executed by a fresh agent that receives only `docs/` and a separately created vanilla Flutter app, may copy what the playbook tells it to copy, must log every gap/source-read in `PLAYBOOK_GAPS.md`, and must reach two consecutive green `e2e run`s plus `check_integration.sh` OK. Every logged gap becomes a doc or harness fix upstream** | R22's "written for an AI agent" is only testable by an agent without the author's context; the gap log turns the exercise into fixes instead of a pass/fail. First exercise (2026-08-26): passed; one harness bug (doctor with `mode: none`) and ten doc gaps found and fixed. |
| D23 | Admin-free fixed user pool (2026-08-27; supersedes D12, D17, amends D11/D14) | **The harness needs no Firebase admin credentials. Test users are a fixed, deterministic pool: `<scope>-<role>@<email_domain>` with one shared `provisioner.pool_password`; scope = the test name by default (own account per test role) or the manifest's `users: {role: label}` override (feature-shared accounts). The APP brings accounts into existence through its regular sign-up flow — "Continue" signs in, or registers when the email is unknown — and the harness never calls Firebase Auth. Real mode needs only `project_id` + Web `api_key` (public identifiers). The backend keys all data by the token's EMAIL, so seeding and account resets need no uid; every account a run uses is reset server-side before and after each test. Parallel runs against one real project share the pool: one run per project at a time.** Removed: service-account key, `googleapis_auth`, marker leases/TTL/heartbeat, `e2e pool`, `e2e register-app`, the stale-lease DoD | No secret of any kind on the orchestrator side; no lease races (D12's measured caveat disappears with the mechanism); the sign-up path is exercised by the suite itself (`returning_user` asserts register → sign-out → sign-in). Doctor probes the real project's key and email/password provider through the client API with a canary sign-in. |
| D24 | Artifact retention and audit memory (2026-08-27) | **`runs/` (gitignored) keeps the newest `run.keep_runs` runs and `run.keep_audits` audit reports, pruned after every run/audit unless `--keep-all`. Audit reports are self-contained (they snapshot each run's `summary.json`). Every audit appends one small JSON entry to `run.history_dir` (`e2e-history/`, committed) and regenerates `HISTORY.md` there: per-test pass rate / p50 / verdict trend over the last audits and a "since the last audit" section (regressions: pass rate down, verdict worsened, p50 +20 %; improvements; new/removed/quarantined tests). `e2e history` regenerates it; doctor warns if the directory is gitignored** | Runs accumulate fast and audits need only their own runs; the memory that matters (how the suite trends) is tiny and belongs in version control. Per-audit files have unique names so parallel branches never conflict; the Markdown is derived and deterministic, so a conflict on it is resolved by regenerating rather than by hand. |
| D25 | Release strategy and versioned migrations (2026-08-27) | **The harness carries a semver `harness/VERSION` inside the vendored tree (absent == `1.0.0`) and a root `CHANGELOG.md` with one section per version, each containing a `Migration` subsection that is written even when empty. Work lands on `dev`, where every change bumps `VERSION` and adds its changelog section in the same commit and is tagged `v<version>`; `dev` → `main` is a plain merge with no version ceremony, so `main` may advance several versions at once. An integrated app upgrades by walking every intervening section in order (1.0 → 1.1 → 1.2 …), never jumping straight to the newest** | The harness is vendored, not depended on: nothing pulls updates for an integrated app, so the version file plus the changelog *are* the upgrade mechanism. Bumping per change on `dev` rather than per release removes the release ritual entirely (the merge is just a merge) at the cost of requiring the discipline on every change; a mandatory-but-possibly-empty migration section makes "nothing to do" distinguishable from "nobody wrote it down", which is what makes an ordered walk trustworthy. |
| D10 | Data isolation for sharded tests (2026-08-26, M2) | **One backend instance per run; the example backend partitions its data by the `X-E2E-Test-Id` header in test mode** (`/test/reset` with the header clears only that partition, without it clears everything) | R19a runs independent tests concurrently against the shared backend, so each test must see only its own data. In the example that is a header-keyed partition; in a real app the same isolation comes from per-test users (M3), which the playbook documents as the pattern. Never partition by anything a production client sends. |

---

## 3. Framework comparison (D5 — resolved: Patrol)

### 3.1 Candidates

**Patrol (LeanCode)** — extends Flutter `integration_test` with native automation (system dialogs, permissions, notifications, WebViews via XCTest/UIAutomator) plus a real CLI runner.
*For:* Dart end-to-end — test modules are Dart functions, which directly serves the modularity requirement (R7) and lets tests share code with seeding/user-management helpers. Native automation is needed the moment a flow hits a permission dialog. Test bundling, sharding, JUnit/XCTest reports. As of 2026 it's at v4.x, in the official Flutter docs, with an MCP server that lets AI agents run/fix tests — relevant given our AI-agent audience.
*Against:* Third-party dependency with a real maintenance risk: community reports (Flutter forum, cited in a Jan-2026 comparison) describe periods where tests "simply not work at all — both locally and on CI," configuration complexity, and timing/synchronization failures. CI stability is its weakest reputation.

**Raw `integration_test` (Flutter SDK)** — no third-party dependency.
*For:* Zero external risk; everything is Dart; fully controllable.
*Against:* No native-dialog automation (permission prompts kill tests), no test runner CLI (we'd build per-test app launches, result collection, reporting ourselves), no built-in artifacts. We would effectively rebuild a worse Patrol.

**Maestro** — black-box YAML flows driving the app from outside.
*For:* Highest CI stability reputation, trivial setup, built-in multi-device features, selectors survive refactors (given Semantics labels).
*Against:* Tests are YAML, not Dart — our modularity model (test modules calling sign-in modules, sharing seeding code) becomes string-level composition; no access to app internals; cross-device *synchronization* (UserA waits for UserB's action) has no first-class primitive, so the orchestrator does all the work over a weaker interface. Requires disciplined Semantics labeling in the target app (worth doing anyway — see R23).

**Appium (flutter driver)** — *rejected.* 2+ hour setup, slowest execution, multi-language support is irrelevant here, and it's the worst fit for an AI-integration playbook (most moving parts to get wrong).

### 3.2 The decisive constraint: multi-user tests

No framework provides cross-device *user-interaction* testing out of the box. In every option, "UserA sends, UserB receives" requires an **orchestrator we write ourselves**: a Dart process that boots N devices, installs the app N times, starts per-user test processes, and synchronizes them (§5). The framework choice therefore determines *how pleasant the per-device layer is*, not whether multi-user works.

This weakens the case for Maestro (its stability advantage doesn't extend to what's hardest for us) and strengthens Dart-native options (the orchestrator, sync primitives, and in-app test code share one language and can share libraries).

### 3.3 Recommendation

**Patrol as primary, with a mitigation strategy:** pin exact Patrol versions, wrap all Patrol-specific APIs behind a thin harness layer so a future migration (to raw `integration_test` or a fork) touches one module, and treat the harness's own self-audit (R14) as the ongoing check on framework flakiness. Raw `integration_test` is the fallback if the spike (below) reproduces the reported instability.

### 3.4 Validation spike — declined; absorbed into milestone 1

Decision (2026-08-26): commit to Patrol without a separate pre-build spike. The risk-management consequence: the **first implementation milestone is the spike's exact content** — two simulators, two Patrol test processes, orchestrator, one cross-user assertion, artifacts captured — built before any other harness feature. If Patrol proves unstable there, the isolation layer (§3.3) bounds the cost of falling back to raw `integration_test`, and only the per-device executor module is rewritten.

---

## 4. Functional requirements

IDs are stable for traceability. "Harness" = the reusable part; "example" = the reference app/backend.

### Platforms & environment
- **R1.** Tests run on iOS simulators and Android emulators, fully locally on a developer's macOS machine (macOS is required by iOS anyway; Android-only mode must work on Linux).
- **R2.** The app under test talks to a **local backend instance** started by the harness. Backend contract for the harness: HTTP/1.1 + JSON. The harness must not depend on backend implementation language (the *example* backend is Dart/shelf per D1).
- **R3.** The harness starts/stops everything itself: emulators/simulators, backend, Firebase emulators. One command from a cold checkout to a passing suite. A `doctor` command verifies local prerequisites (Xcode, Android SDK, ports free, Flutter version) with actionable errors.

### Test structure
- **R4.** Single test, named subset (tags), and full-suite execution from one CLI.
- **R5.** Test taxonomy with tags at minimum: `smoke`, `single-user`, `multi-user`. Runner filters by tag.
- **R6.** Comprehensive error handling: any failure (app crash, backend 5xx, timeout, device loss) produces a diagnosable artifact bundle (R11) and a non-zero exit with a summary pointing to it. No silent failures, no hangs — everything has a timeout.
- **R7.** **Modularity:** tests compose from reusable modules (e.g. `signIn(user)`, `createChat(a, b)`). A feature test invokes the sign-in module, then runs its own steps. Modules are ordinary Dart functions with typed inputs/outputs — no framework magic.
- **R8.** Every test declares its **preconditions** (required seed state, user type) and the harness satisfies them before the test body runs — this is what makes modules reorderable and tests independently runnable.

### State, users, data
- **R9.** **User state reset:** every test starts from a known state. Two supported reset flows, both implemented in the example: (a) app-level — wipe app data / reinstall between tests; (b) account-level — server-side reset of a user's data via a test-only backend endpoint.
- **R10.** **Test user management** (Firebase Auth), behind one `UserProvisioner` interface with two implementations:
  - *Ephemeral* (default, emulator): create fresh users per run; wipe the Auth emulator between runs. Zero cleanup logic to maintain.
  - *Pooled* (real Firebase): fixed pool of test accounts, lease/release semantics with per-lease data cleanup, stale-lease recovery (a crashed run must not poison the pool), and concurrency-safe leasing so parallel runs don't collide.
  Switching implementations is configuration, not code change.
- **R11.** *(moved to Observability, see R12–R13)*
- **R16.** **Data seeding:** declarative seed fixtures (JSON/Dart) loaded through a test-only backend seeding endpoint — never by driving the UI to create data and never by writing to the datastore behind the backend's back. Named seed profiles (e.g. `user-with-history`) reusable across tests. Test-only endpoints are compiled out or hard-disabled outside test mode.

### Observability
- **R12.** Every test run (pass or fail) produces, in a human-browsable layout:
  ```
  runs/<timestamp>_<run-id>/
    summary.html            # index: all tests, status, duration, links
    summary.json            # machine-readable equivalent for AI agents
    <test-name>/
      <device-or-user>/     # one per device in multi-user tests
        video.mp4
        screenshots/        # auto at key steps + on failure
        app.log
        test.log
      backend.log           # per-test slice, correlated
      firebase.log
  ```
- **R13.** Log **correlation**: a run-id/test-id propagated from test → app (HTTP header) → backend logs, so one grep connects all three. Screenshots auto-captured on every failure and at module boundaries.

### Multi-user / parallelism
- **R17.** The harness orchestrates **N devices in one test** (N=2 in the example; design for N>2 — pairing flows, group interactions). Per-device roles (UserA/UserB) with independent artifact capture per device.
- **R18.** A **synchronization primitive** between per-user test processes (e.g. named barriers/events via the orchestrator: `await sync.barrier('message-sent')`), so cross-user assertions are deterministic, not sleep-based. No `sleep()`-based coordination anywhere in the harness.
- **R19.** Parallelism has two independent axes, both supported: (a) *inter-test* — shard independent tests across devices to cut wall time; (b) *intra-test* — multiple devices inside one test (R17). Resource management (ports, device handles, user leases) must be collision-free under both.

### Self-audit
- **R14.** Built-in reliability audit: run a test/suite N times, report per-test pass rate, duration percentiles (p50/p95), failure clustering (same step failing repeatedly ⇒ product bug; scattered ⇒ flaky infra). Output feeds a flake quarantine list (tag-based) so known-flaky tests don't block runs but stay visible.
- **R15.** Performance audit: per-run timing breakdown (device boot, app install, per-module durations) to find where suite time goes.

### Example scope (reference repo)
- **R20.** Example app: sign-in (Firebase Auth), a trivial single-user feature, and a two-user interaction (message send/receive is fine). Real-time delivery in the example uses **polling** to stay within HTTP/1+JSON; the playbook documents how the same wait-for-cross-user-state pattern applies when a target app uses websockets/SSE/push.
- **R21.** Verified tests shipped: at least one smoke test, one single-user feature test (composing the sign-in module), one two-user interaction test, and one test demonstrating seeding + account-level reset.

### Playbook & docs
- **R22.** Integration playbook as a structured `docs/` tree (D4): step-by-step integration guide, architecture decision records, troubleshooting, and a machine-checkable "definition of integrated" checklist an AI agent can self-verify against.
- **R23.** The playbook mandates stable widget keys / Semantics identifiers in the target app and provides the convention — this is what keeps selectors from being the #1 flake source, regardless of framework.
- **R24.** The harness is **versioned** (semver in `harness/VERSION`, which travels with the vendored copy; absent == `1.0.0`) and every version has a `CHANGELOG.md` section carrying a **Migration** subsection — empty when there is nothing to do, never missing. An app upgrading from an older version applies every intervening version's migration **in order**, never a single jump.

---

## 5. Architecture implications (accepted, not open)

The multi-user requirement forces this shape; recording it so it's not re-litigated later:

```
orchestrator (Dart CLI)
 ├─ environment manager: boots simulators/emulators, backend, Firebase emulators
 ├─ user provisioner: ephemeral | pooled (R10)
 ├─ seed loader (R16)
 ├─ sync server: barriers/events for multi-device tests (R18)
 ├─ artifact collector: video, screenshots, logs → runs/ tree (R12)
 └─ per-device test executor: runs the framework-level tests (D5)
```

The framework choice (D5) affects only the last box. Everything else is ours and framework-agnostic — which is also the migration insurance for §3.3.

---

## 6. Brainstormed additions (per original item 19)

Proposed additions, each cheap where it stands on infrastructure we already need. Marked **[in]** = include in v1, **[later]** = document as extension, don't build.

- **[in] `doctor` command** (folded into R3) — the single biggest support-cost reducer for an AI-agent-integrated tool.
- **[in] HTML run report** (folded into R12) — `summary.html` index per run; humans verify runs by clicking, not by spelunking directories.
- **[in] Flake quarantine** (folded into R14).
- **[in] Machine-readable outcomes** (`summary.json`, R12) — the AI agent that integrates the harness will also *run* it; give it structured results.
- **[later] Backend request/response capture** per test (HTTP tap or backend-side echo log) — powerful for diagnosing "wrong data" failures; adds a proxy moving part, so v2.
- **[later] Visual regression (golden screenshots)** — infrastructure (screenshots per step) is already there; diffing policy is a project of its own. *Precondition added in M2:* the Android emulator now renders on the host GPU (`devices.android.gpu: host`, needed for adb stability — see `_e2e/logs/m2_verification_notes.md`), so screenshot pixels are machine-dependent. Goldens would need a pinned **software** renderer (`swangle`/`swiftshader`) to be portable across machines.
- **[later] Network condition simulation** (offline, slow 3G) — valuable, platform-fiddly.
- **[later] Push notification testing** — FCM emulator + `simctl push` on iOS; document the recipe, don't build it into the example.
- **[later] Deep-link entry tests** — cheap recipe, document it.
- **[later] Test-clock control** — backend test endpoint to freeze/advance time for time-dependent flows; document the pattern (the example backend can carry a trivial version if a test needs it).
- **[later] CI recipe** — everything is CLI-driven and headless-capable by design (R3/R4), but a maintained CI config (macOS runners for iOS) is explicitly out of v1 scope. *Constraint added in M2:* the default `devices.android.gpu: host` requires a usable GPU driver on the machine (headlessness itself is fine — `-gpu host -no-window` was verified working); a GPU-less runner must set `devices.android.gpu: swangle` in e2e.yaml. *Out of scope entirely for v1: device farms, physical devices, web/desktop targets.*

---

## 7. Open questions — all resolved 2026-08-26

Resolutions recorded as D5–D9 in §2: no pre-build spike (Patrol committed, two-device slice is milestone 1), dedicated test-only Firebase project for pooled runs, 1+1 recent-OS default device matrix, polling for the example's delivery, keep-last-20 artifact retention. No open questions remain; next step is implementation planning (milestones + repo layout).

---

## 8. Non-goals (v1)

Unit/widget testing guidance, performance/load testing of the backend, device farms, physical devices, web/desktop platforms, CI pipeline maintenance, App Store/Play build lanes.
