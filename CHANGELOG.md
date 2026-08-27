# Changelog

The current version is in [`harness/VERSION`](harness/VERSION) — it travels
with the vendored copy, so an integrated app always knows what it is on. **A
vendored harness with no `harness/VERSION` file is `1.0.0`.**

Every released version has exactly one section here, newest first, and every
section carries a **Migration** subsection — even when it reads "None." An
empty migration means there is nothing to do; it never means nobody wrote it
down. A missing section means that version was never released.

Versions are semantic, judged from the perspective of **an app that has
already vendored the harness**:

| Bump | Means | Migration typically says |
|---|---|---|
| **MAJOR** | The integrated app must change something or it breaks: `e2e.yaml` schema, the backend `/test/*` contract, a removed `test_support` API, a renamed manifest key | Required steps, in order |
| **MINOR** | New capability, backward compatible. Existing integrations keep working untouched | Optional steps, or "None" |
| **PATCH** | Bugfix or docs; nothing integration-facing changed | "None" |

**Upgrading a vendored copy:** follow
[docs/playbook/09-upgrading.md](docs/playbook/09-upgrading.md) — apply every
section between your `harness/VERSION` and your target **in order**
(1.0 → 1.1 → 1.2 → …), never jumping straight to the newest. Skipping a
section is how a required step goes missing.

**Releasing (maintainers):** [docs/releasing.md](docs/releasing.md).

---

## 1.2.2 — 2026-08-27

The two remaining review findings from 1.2.0 worth fixing before the release
sees wide use: a required check that failed correctly-configured apps, and a
secret that could reach a log by a route nothing scrubbed.

### Fixed

- **Flavored apps no longer fail the Firebase config check.** 1.2.0 looked
  only at `android/app/google-services.json` and
  `ios/Runner/GoogleService-Info.plist`, but the Google Services Gradle plugin
  also searches `android/app/src/<flavor>/` and
  `src/<flavor>/<buildType>/`, and a flavored iOS project keeps the plist in a
  per-flavor directory and copies it in with a build phase. A correctly
  configured app therefore failed a **required** check with no way to opt out.
  Both `e2e doctor` and `check_integration.sh` now accept the file anywhere
  under `android/app/src/` and `ios/` respectively, skipping generated and
  vendored directories (`Pods/`, `build/`, `.symlinks/`, `ephemeral/`).
- **A backend error body can no longer carry `backend.test_header` into
  `orchestrator.log`.** A failed `/test/*` call raises a `StateError` that
  interpolates the backend's own response body; a backend that echoes the
  offending header in its 403 would have written the configured secret there
  verbatim, and no redaction pass covered `orchestrator.log`. Every configured
  value is now scrubbed out of that body before the error is raised, and the
  claims in playbook 03 and `e2e.local.yaml.template` are restated to describe
  what the harness actually does rather than promising a blanket log filter.

### Migration

None.

---
## 1.2.1 — 2026-08-27

Three defects in 1.2.0's own new code, found by a clean-context review of the
release, plus two documentation claims that were never true.

### Fixed

- **The Firebase-config doctor check is gated on the app's build, not on
  `firebase.mode`.** 1.2.0 ran it only when `firebase.mode != none`, but the
  `google-services` Gradle plugin fails the build whenever it is applied —
  including for an app that uses Firebase Analytics or Crashlytics while
  running the harness with `firebase.mode: none`. That app skipped the check
  and still lost a full build to `:app:processDebugGoogleServices`, which is
  precisely the failure 1.2.0 claimed to prevent. `check_integration.sh` was
  already gated correctly and is unchanged.
- **The iOS bootstrap guard no longer skips on a non-Patrol UI-test target.**
  1.2.0 matched `class RunnerUITests` as well as Patrol's own markers, and
  Xcode's stock UI Testing Bundle template declares exactly that. An app with
  such a target got `skipped (exists)`, never received
  `PATROL_INTEGRATION_TEST_IOS_RUNNER`, and built a UI-test bundle containing
  no Patrol tests — while `check_integration.sh`, matching the same way,
  certified the broken state as `[PASS]`. Both now require the
  `PATROL_INTEGRATION_TEST_IOS_(RUNNER|MODULE)` markers. The Android guard was
  always correctly specific and is unchanged.
- **`e2e doctor` no longer dies on an unreadable or non-UTF-8 build file.**
  The gradle/pbxproj scan ran outside the probe's error handling, so one
  malformed byte in `build.gradle` threw out of `doctor()` with a stack trace
  before it had reported anything. It now decodes leniently and treats an
  unreadable file as "does not mention", so doctor always reports.

### Documentation

- 1.2.0's Migration said the new check "blocks a run". It does not: `e2e run`
  never invokes `doctor()`, which is called only by the `doctor` command. The
  check blocks `e2e doctor` (and `check_integration.sh` with it), and the
  Migration now says so and tells you to run doctor yourself after upgrading.
  `docs/troubleshooting.md` carried the same overclaim.

### Migration

None. Both behaviour fixes make the tools *more* correct on projects they
previously mishandled; no configuration or integration change is required.
If you bootstrapped an iOS project with 1.2.0 and it has a `RunnerUITests`
target that never got Patrol wired in, re-run
`bash harness/tools/patrol_bootstrap.sh <app>` — it will now write the entry
point it previously skipped.

---
## 1.2.0 — 2026-08-27

Five findings from the field report on migrating an existing hand-rolled
Patrol suite (issues #1, #2, #3, #4, #7). Two of them produced an
unbuildable project, one cost a full build to discover, one was a universal
paper cut, and one was a security hole in the reference backend.

### Fixed

- **The bootstrap no longer overwrites existing native entry points**
  (#1). `patrol_bootstrap.sh` wrote `MainActivityTest.java` and
  `RunnerUITests.m` with an unconditional `cat >`, so a project with a
  Kotlin `MainActivityTest.kt` got a `.java` sibling and every Android
  build died on a redeclaration error that never named the real problem —
  and hand-written comments in both files were destroyed on every re-run.
  Detection is now by **content, not filename**: `PatrolJUnitRunner`
  anywhere under `androidTest/`, and a Patrol UI-test marker anywhere under
  `ios/RunnerUITests/`. A pre-existing entry point of any extension prints
  `skipped (exists)`. `check_integration.sh`'s two matching criteria were
  filename-exact for the same reason and now accept `.kt` / `.swift` too.
- **Stale Patrol SwiftPM references are cleaned out of `Runner.xcodeproj`**
  (#2). Disabling Swift Package Manager (which the bootstrap does, because
  Patrol's iOS setup is CocoaPods-based) stops Flutter generating
  `ios/Flutter/ephemeral/Packages/.packages/patrol-<version>/`, so a project
  that previously wired Patrol *as a local Swift package* pointed at a path
  that no longer existed and `xcodebuild` failed to resolve dependencies
  before building anything. New vendored tool `harness/tools/ios_spm_cleanup.rb`
  removes the `XCLocalSwiftPackageReference`, its
  `XCSwiftPackageProductDependency` and the `Frameworks` entry (idempotent;
  unrelated packages are left alone), wired in as the bootstrap step
  `ios: stale SwiftPM patrol package`.

### Added

- **`e2e doctor` checks the Firebase app config files** (#3). When
  `firebase.mode != none`, it asserts `android/app/google-services.json` and
  (macOS only) `ios/Runner/GoogleService-Info.plist`. These are gitignored in
  most Flutter repos, so a fresh clone or worktree lacks them and the failure
  previously surfaced minutes into a run as
  `Execution failed for task ':app:processDebugGoogleServices'`, buried in
  `runs/<id>/<test>/<role>/test.log`. The check is conditional on the app's
  build actually consuming the files (gradle applying `google-services`, the
  xcodeproj referencing the plist), so REST-based Firebase apps are unaffected.
  (Re-gated in 1.2.1 — see below.)
- **`e2e doctor` warns about a stale patrol Swift package** (#2) when SPM is
  disabled and the pbxproj still references one. macOS only, non-blocking.
- **`backend.port_flag`** (#4) — a template for how the run's port reaches the
  backend, replacing a hardcoded `--port <n>`. Accepts a string or a list, and
  substitutes every `{port}`:

  ```yaml
  backend:
    port_flag: "--server.port={port}"     # Spring Boot
    # port_flag: ["-p", "{port}"]         # Rails
    # port_flag: "127.0.0.1:{port}"       # Django-style positional
    # port_flag: ["--port", "{port}"]     # default — today's behaviour
  ```

  A template with no `{port}` is a `ConfigError` at load, so it fails at
  `doctor` rather than starting a backend on the wrong port. Playbook 03 also
  now presents the wrapper script as a documented first-class pattern (with
  the `exec` requirement, so the harness's SIGTERM still reaches the server).
- **`backend.test_header`** (#7) — an optional shared secret sent on `/test/*`
  requests. The value is treated as a secret everywhere the harness redacts:
  `summary.json` records header *names* and `<set>`, `test.log` values are
  scrubbed, `doctor` prints names only. Unset by default, so existing requests
  are byte-identical. It belongs in `e2e.local.yaml`.

### Security

- **The `/test/*` surface is documented as loopback-only, and the reference
  backend now enforces it** (#7). `E2E_TEST_MODE` is an enable flag, not
  authentication: a surface that deletes arbitrary user data and must work
  *before* the account exists cannot authenticate its caller, so an integrator
  binding to `0.0.0.0` had an unauthenticated, network-reachable
  data-deletion endpoint. Playbook 03 §3.2 now recommends binding to
  `127.0.0.1` **and** rejecting non-loopback remote addresses, failing
  **closed** on an absent or unparseable one. `example/backend` did bind to
  `InternetAddress.anyIPv4` — it now binds loopback (with a `--host` escape
  hatch) and carries a fail-closed `loopbackOnly()` middleware that holds
  regardless of bind address.

### Migration

Three of the five need nothing. Two may need action:

1. **`e2e doctor` can newly fail** with `Firebase app config files` if your
   app's build applies the `google-services` plugin (or the xcodeproj
   references `GoogleService-Info.plist`) but the files are not present.
   This is surfacing a real defect that previously cost a full build to
   discover: run `flutterfire configure` in the app dir, or copy the files
   from another checkout. It is a *required* check, so it fails
   `e2e doctor` (and `check_integration.sh` with it) — note that `e2e run`
   does not invoke doctor, so run it yourself after upgrading.
2. **Lock your own backend's `/test/*` surface to loopback.** This is the
   security fix above and the harness cannot do it for you — the endpoints
   live in your backend. Bind to `127.0.0.1` and add a fail-closed
   remote-address filter; playbook 03 §3.2 has the pattern and a worked
   example. If you copied `example/backend`, re-copy `bin/server.dart` and
   `lib/api.dart`, or pass `--host 0.0.0.0` in `backend.command` if you
   genuinely need off-host reachability (the filter still protects `/test/*`).

Optional:

- Re-run `bash harness/tools/patrol_bootstrap.sh <app>` to pick up the
  SwiftPM cleanup if your iOS project ever wired Patrol through SPM. The
  bootstrap is now conservative about native entry points, so a re-run will
  no longer clobber annotations you added to them.
- Adopt `backend.port_flag` if you keep a wrapper script whose only job is
  translating a port flag. The default is unchanged, so doing nothing is
  correct.
- `backend.test_header` is opt-in and only worth it if you prefer a shared
  secret to loopback binding.

---
## 1.1.1 — 2026-08-27

Documentation only. Adds a copy-pasteable **Update prompt** to the reference
repo's `README.md`, next to the existing bootstrap prompt, for handing an
upgrade to an agent working inside an app that already has the harness. It
does not need to be told which version the app is on — it derives that from
`harness/VERSION` (absent = 1.0.0) and walks this changelog from there.
`playbook/09-upgrading.md` points back at it.

### Migration

None — nothing in `harness/` changed. Re-vendor only if you want the
refreshed docs.

---

## 1.1.0 — 2026-08-27

Multi-role tests now fail as soon as one role fails. Previously a partner
kept polling to its own deadline — commonly 5–10 minutes, since those waits
are sized to absorb cold-cache build skew — and then threw `SyncTimeout`
naming *itself* rather than the role that actually broke. A red two-device
run paid a full wait budget and put the misleading error first.

### Added

- `PartnerFailure` (exported from `e2e_test_support`): thrown by `barrier`,
  `waitForEvent` and `waitForValue` when a *different* role in the same test
  has failed. Carries that role's name and message, so the first error a
  reader sees is the true one. A distinct type from `SyncTimeout`, which now
  means only "nobody arrived and nobody failed" — still building, still
  booting, or a process that died without reaching `guard`.
- Opt-out for tests that legitimately expect a partner to fail:
  `sync.failFast = false` for a whole test, `failFast: false` on one wait.
- The sync server records the first failure per run+test namespace and
  attaches it as `failed: {role, message}` to the poll responses waiters
  were already making (`/sync/count`, and the 404s of `/sync/event` and
  `/sync/kv`) — one request per poll, unchanged.

### Changed

- `SyncClient.guard` reports the failure *before* taking the failure
  screenshot. The screenshot can take tens of seconds and every partner
  spends that time still waiting. Artifacts are unaffected — the screenshot
  is still taken, still before the rethrow.

### Migration

None. Existing multi-role tests get fail-fast without any change: the
signal is published by `guard`, which every test body is already wrapped in.

Two notes if you are re-vendoring:

- Re-vendor **`harness/test_support` and `harness/orchestrator` together.**
  A mismatched pair degrades gracefully rather than breaking (a new client
  against an old server never sees the field and behaves as it did in 1.0.0;
  an old client against a new server ignores it), but you only get the
  feature with both.
- A test that *expects* a partner to fail — rare, but a suite testing
  failure handling would — must now set `sync.failFast = false`, or it will
  end early with `PartnerFailure` instead of reaching its own assertion.

---

## 1.0.0 — 2026-08-27

Baseline. Everything shipped through milestones M1–M5 is this version: the
`e2e` orchestrator CLI (`doctor` · `run` · `audit` · `history` · `list` ·
`devices` · `prune`), the zero-dependency `test_support` package, the Patrol
executor, the sync server, the admin-free fixed user pool (D23), artifact
retention and audit memory (D24), the integration playbook, and
`harness/tools/{patrol_bootstrap,check_integration}.sh`.

### Added

- `harness/VERSION` and this changelog: the harness is now versioned, and a
  vendored copy carries its version with it.
- [`docs/releasing.md`](docs/releasing.md) — the release process: every change
  on `dev` bumps `VERSION` and writes its own section here; `dev` → `main` is
  a plain merge with no ceremony attached.
- [`docs/playbook/09-upgrading.md`](docs/playbook/09-upgrading.md) — how an
  integrated app moves from one harness version to a newer one.

### Migration

None — this is the baseline. Any harness copy vendored before this release
is `1.0.0` and needs no changes; write `1.0.0` into its `harness/VERSION` (or
copy the file from the reference repo) so the next upgrade has a starting
point.
