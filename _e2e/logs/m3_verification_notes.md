# M3 verification log — 2026-08-26

Scope (implementation_plan.md §3, M3): Firebase Auth emulator in the run
lifecycle, `UserProvisioner` with ephemeral + pooled implementations (the
pooled one verified against the dedicated test project, D6), seeding
endpoints + named profiles (R16), both reset flows (R9a/R9b), example app
to R20, suite to R21 built from modules.

DoD status:
- `m3/dod_both_modes.sh` — PASS: all four R21 tests pass in ephemeral mode
  (Auth emulator, `demo-e2e-harness`, no credentials) AND in pooled mode
  (`E2E_FIREBASE_MODE=real E2E_PROVISIONER_MODE=pooled`, real test project,
  service account). Summary assertions: a user per role, `poolIndex` set in
  pooled mode, no password anywhere in `summary.json`, the password
  dart-define redacted in `test.log`, `firebase.log` present in emulator
  runs, no lease left behind by the script's own runs.
  Log: `_e2e/logs/m3_dod_both_modes.log`.
- `m3/dod_stale_lease.sh` — PASS: a pooled run (pool of 1, TTL 45 s) is
  SIGKILLed right after leasing slot 1; `e2e pool` shows the orphaned lease
  as held; the next pooled run waits out the TTL, logs `reclaiming stale
  lease on slot 1`, passes, and leaves the slot free.
  Log: `_e2e/logs/m3_dod_stale_lease.log`.
- Unit level: `harness/orchestrator/test/provisioner_test.dart` runs both
  provisioners against a live Auth emulator — fresh user + wipe, lease /
  rotate / release, crashed-holder reclaim after TTL, heartbeat keeps a
  live lease, six concurrent contenders never share a slot, winner
  resolution is deterministic. 32 orchestrator tests + 7 backend tests.
- M2 DoDs still hold with the new suite (`m2/dod_kill_backend.sh` now
  targets `cross_user_chat`).

Timings (warm, this machine): full suite ~150 s ephemeral, ~170 s pooled.
Auth emulator start ~2.2 s. Per-test provisioning (acquire + seed): ~7 ms
on the emulator, 3–7 s against the real project (several REST round trips,
each ~300 ms: marker create, settle 1.5 s, rival check, account lookup,
password rotation).

## What was built

- **Auth emulator per run** (`env/firebase_emulator.dart`): `firebase
  emulators:start --only auth` with a per-run `firebase.json` (auth, hub,
  logging ports from the allocator; host 0.0.0.0 so Android's 10.0.2.2
  reaches it), readiness by polling `/`, output to `firebase.log`. No Java:
  the Auth emulator lives inside the CLI. `m1/step4_firebase.sh` installs
  the CLI (`brew install firebase-cli`).
- **Admin client** (`users/auth_admin.dart`): Identity Toolkit v1
  `projects.accounts.*` over REST; bearer `owner` on the emulator, an OAuth2
  token minted from the service account (`googleapis_auth`) on the real
  project. Also admin-v2 config read (doctor: is email/password enabled?),
  Web API key discovery and Web app registration via the Firebase
  Management API.
- **Provisioners** (`users/provisioner.dart`): `EphemeralProvisioner`
  (`<run>-<test>-<role>@e2e.example.com`, emulator wiped in `prepare()`);
  `PooledProvisioner` (marker-user leases, see D12; heartbeat at TTL/3;
  password rotation + session revocation on every acquire and release;
  bounded wait for a busy pool). `e2e pool` shows slots and leases.
- **Backend** (`example/backend`): bearer ID-token auth verified through
  `accounts:lookup` (D13), per-uid notes, email-pair conversations,
  `/test/seed`, `/test/reset/user`, `/test/reset` under `E2E_TEST_MODE=1`.
  `AUTH_BASE_URL` / `AUTH_API_KEY` come from the orchestrator.
- **Seeding** (`seed/seed_loader.dart`, `example/seeds/`): profiles are
  JSON files; the manifest's `seed: {role: profile}` applies one before the
  body; `sync.seed('profile')` applies one mid-test; both go through the
  backend's seed endpoint with the role's user attached.
- **Resets**: R9a `DeviceManager.clearAppData` (Android `pm clear`, iOS
  `simctl uninstall`) before every role when `executor.reset_app_data`;
  R9b `sync.resetAccount()` → `/test/reset/user`; pooled slots are also
  reset on acquire and on release (per-lease data cleanup).
- **Runner**: emulator → backend (with auth env) → sync → provisioner
  `prepare()` → devices; per test: acquire a user per role → reset/seed →
  clear app data → run with `E2E_USER_*`, `E2E_AUTH_URL`,
  `E2E_FIREBASE_API_KEY` defines (password redacted from the logged
  command) → release. Emulator death aborts the run like backend death.
- **App** (`example/app/lib/main.dart`): sign-in page (REST, D11), home
  with Notes and Chat tabs, session persisted with `path_provider`, stable
  keys on every interactive widget. **Tests**: `smoke_sign_in`,
  `single_user_notes`, `cross_user_chat` (A iOS / B Android),
  `seeded_notes_reset`; modules `sign_in`, `notes`, `chat`.
- **test_support**: `TestContext.user` (uid/email/password), `authUrl`,
  `apiKey`; `SyncClient.seed()`, `SyncClient.resetAccount()`.
- **Doctor**: firebase CLI, real-project access + email/password enabled,
  Web API key presence/discovery, pinned emulator port free, seed profiles
  parse, leftover Auth emulator processes.
- **CLI**: `register-app`, `pool`; env overrides
  `E2E_PROVISIONER_POOL_SIZE`, `E2E_PROVISIONER_LEASE_TTL_SECONDS`.

## What broke and what changed

### Firebase Auth email uniqueness is not atomic for in-flight creates
The first pooled run against the real project handed pool slot 1 to two
concurrently scheduled tests: both marker creates succeeded. Measured
directly: 6 simultaneous admin `signUp` calls for one new email all
returned 200 and `accounts:lookup` then found 6 accounts with that email;
a *sequential* duplicate is rejected with `EMAIL_EXISTS`. The emulator, by
contrast, is strictly serial (the unit test with six contenders passed).
Fix, both layers: acquires within one process are serialized by a mutex
(the only case that occurs inside a run), and after creating a marker the
contender waits 1.5 s, re-reads every account with the marker's email and
yields — deleting its own marker — unless its marker is the oldest (ties:
lowest uid). Recorded as the measured caveat in D12, with the residual
cross-machine window stated honestly.

### The real project had no registered app, hence no Web API key
The app signs in with the project's Web API key; the project had never had
an app registered. Added `e2e register-app` (Management API, creates a Web
app `e2e-harness` once) and run-time discovery of the key from any
registered app, so `firebase.api_key` became optional (D17). Ran it once
against the test project.

### Emulator readiness probe
The emulator's `/` answer is pretty-printed JSON (`"ready": true`); the
first probe matched `"ready":true` and timed out. Now parsed as JSON.

### Stale lease from the pre-fix run
The broken run left an orphaned marker on slot 1 (its release removed the
wrong lease). The DoD scripts initially demanded "every slot free" after a
run, which is wrong under parallel runs; they now assert only that the
script's own runs left nothing behind, and the stale-lease DoD waits for
foreign live leases to expire instead of failing. The orphan expired at
13:18Z and was reclaimed by the next pooled run — the mechanism working as
designed.

### Web API key echoed into test.log
The logged `patrol test` command line carried `--dart-define=E2E_FIREBASE_API_KEY=AIza…`
in pooled runs. It is a public client identifier (D17), but the harness
redacts it everywhere else, so the executor now replaces every secret
define's *value* in every logged line (command header and Patrol output),
for both `E2E_USER_PASSWORD` and `E2E_FIREBASE_API_KEY`. Verified: no
`AIza…` string anywhere in a pooled run bundle.

## Known gaps carried into M4
- `executor.prebuild` still parsed but not implemented; Android video still
  capped at 180 s; Android `app.log` unfiltered logcat.
- Pooled acquire costs 3–7 s per role on the real project — fine for runs,
  worth batching (one lookup for all slots) if the audit (M4) makes it
  visible.
- The example app's sign-in is REST-based (D11); an SDK-based sign-in
  (`firebase_auth` + `useAuthEmulator`) is documented for the playbook but
  not exercised by the example.

## Addendum 2026-08-27 — D23: admin-free fixed user pool

Replaced the ephemeral/pooled provisioners (service account, marker-user
leases, TTL, heartbeat, password rotation, `e2e pool`, `e2e register-app`,
`m3/dod_stale_lease.sh`) with ONE deterministic pool the harness never
touches: `<scope>-<role>@<email_domain>` + `provisioner.pool_password`;
scope = test name or the manifest's `users: {role: label}` override. The
app's "Continue" signs in, or registers on `EMAIL_NOT_FOUND` /
`INVALID_LOGIN_CREDENTIALS` (regular sign-up flow), and shows which path
it took (`auth_mode_registered` / `auth_mode_signed-in`). The backend keys
everything by the token's email, so seeding and account resets need no
uid; the runner resets every account a run uses before and after each
test. Real mode needs only `project_id` + Web `api_key` (+ a pool
password); `e2e doctor` probes key and provider with a canary sign-in.

Verification: emulator mode 6/6 (`runs/2026-08-27T1224_988`), DoD emulator leg `runs/2026-08-27T1229_435`, real leg 6/6 `runs/2026-08-27T1232_800`, incl. the new
`returning_user` (registered → sign-out → signed-in) and `cross_user_chat`
on the shared `chat-a`/`chat-b` accounts; `m3/dod_both_modes.sh` revised
(emulator + real) — result in `_e2e/logs/m3_dod_both_modes.log`.
Orchestrator: `googleapis_auth`/`http` dropped; 32 unit tests.
