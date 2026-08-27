# 04 — Changes inside the app

Keep these minimal and production-safe: every value has a default that is
correct in a production build.

## 4.1 Read the e2e configuration from dart-defines

The orchestrator compiles each test role with `--dart-define`s. The same
defines reach app code and test code (they run in one process). In your
app's config/DI layer:

```dart
/// Injected by the e2e orchestrator; production builds keep the defaults.
const kBackendUrl = String.fromEnvironment('E2E_BACKEND_URL', defaultValue: 'https://api.example.com');
const kRunId  = String.fromEnvironment('E2E_RUN_ID',  defaultValue: '');
const kTestId = String.fromEnvironment('E2E_TEST_ID', defaultValue: '');
// Only if the app signs in with Firebase Auth (4.3):
const kAuthUrl = String.fromEnvironment('E2E_AUTH_URL', defaultValue: 'https://identitytoolkit.googleapis.com/v1');
const kFirebaseApiKey = String.fromEnvironment('E2E_FIREBASE_API_KEY', defaultValue: 'REPLACE_WITH_WEB_API_KEY');
```

Full list of defines the harness sets: `E2E_RUN_ID`, `E2E_TEST_ID`,
`E2E_ROLE`, `E2E_PARTIES`, `E2E_BACKEND_URL` (only with a backend),
`E2E_SYNC_URL`, `E2E_RUN_SEQ`, and — unless `firebase.mode: none` —
`E2E_AUTH_URL`, `E2E_FIREBASE_API_KEY`, `E2E_USER_EMAIL`,
`E2E_USER_PASSWORD`, `E2E_USER_SCOPE`. Test code reads them through
`TestContext.fromEnvironment()` (step 06); app code reads only what it
needs. URLs are already resolved for the device (`10.0.2.2` on Android
emulators, `127.0.0.1` on iOS simulators) — never hard-code loopback
addresses.

## 4.2 Log correlation header

On every backend request:

```dart
if (kRunId.isNotEmpty)  request.headers.set('X-E2E-Run-Id', kRunId);
if (kTestId.isNotEmpty) request.headers.set('X-E2E-Test-Id', kTestId);
```

That header is how `runs/<run>/<test>/backend.log` gets sliced per test.
(Android: Dart's `HttpClient` is not subject to the platform's cleartext
policy, so plain `http://10.0.2.2` works; iOS ATS exempts loopback.)

## 4.3 Sign-in (only if the app has Firebase Auth)

The harness assigns each role a **pool account** — a deterministic email
(`<scope>-<role>@<email_domain>`) and one shared password — and hands the
test its credentials. The account may not exist yet: **the app registers
it through its own sign-up flow on first use and signs in afterwards**
("register or continue"). The harness never creates accounts. The app
must therefore be able to both sign up and sign in against `E2E_AUTH_URL`:

- **REST (what the reference app does; no native SDK config):** POST
  `${kAuthUrl}/accounts:signInWithPassword?key=${kFirebaseApiKey}`; on
  `EMAIL_NOT_FOUND` / `INVALID_LOGIN_CREDENTIALS` POST
  `${kAuthUrl}/accounts:signUp` with the same body → `idToken`, `localId`.
  See `<REF>/example/app/lib/main.dart` `AuthClient.continueWith`. Show
  which path was taken (the reference app's `auth_mode_registered` /
  `auth_mode_signed-in` keys) so a test can assert it.
- **`firebase_auth` SDK:** keep it, and in e2e builds call
  `FirebaseAuth.instance.useAuthEmulator(host, port)` with host/port parsed
  from `E2E_AUTH_URL`; `signInWithEmailAndPassword`, falling back to
  `createUserWithEmailAndPassword` on `user-not-found` /
  `invalid-credential`. Details and pitfalls in
  [../patterns/firebase-auth.md](../patterns/firebase-auth.md).

If the app has no Firebase Auth, skip this and set `firebase.mode: none`.

## 4.4 Stable keys (mandatory — R23)

Every widget a test touches or asserts on gets a stable `Key('snake_case')`
— fields, buttons, list containers, list items (`Key('note_$id')`), error
banners, page roots (`Key('sign_in_page')`). Text and position change;
keys don't. Convention and examples: [../patterns/stable-keys.md](../patterns/stable-keys.md).

## 4.5 Polling / real-time state

Tests wait for state, so the app must reach a frame-quiet state: when
polling, call `setState` only when data actually changed (see the
reference app's `_refresh`). If the app uses websockets/SSE/push, the same
wait-for-state assertions apply — see
[../patterns/realtime-transports.md](../patterns/realtime-transports.md).

## 4.6 Persisted session (optional but recommended)

If the app restores a session on launch, the harness's app-level reset
(`executor.reset_app_data: true`, R9a) must wipe it — that is automatic
(`pm clear` / `simctl uninstall`), and your sign-in test proves it by
asserting the sign-in page shows first.

## Done when

`flutter analyze` is clean and the app still builds/runs in production
configuration (defaults). Whether it actually talks to the backend under
the `E2E_*` defines is proven by the first `e2e run` (step 07) — don't run
the app by hand on the shared devices.

Next: [05-patrol-bootstrap.md](05-patrol-bootstrap.md)
