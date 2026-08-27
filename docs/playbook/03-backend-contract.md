# 03 — Backend contract

The harness is backend-language-agnostic: it only needs HTTP/1.1 + JSON and
the small contract below. The reference backend (`<REF>/example/backend`,
Dart/shelf, ~250 lines) implements all of it and doubles as a **starter
backend** for apps that have none.

## 3.1 Process contract (harness → backend)

| What | Detail |
|---|---|
| Start | `backend.command` + `--port <n>` in `backend.dir`; a free port per run |
| Environment | `E2E_TEST_MODE=1` (enables `/test/*`); only when users are provisioned (`firebase.mode` ≠ `none`): `AUTH_BASE_URL` (Identity Toolkit v1 base to verify ID tokens: the emulator's `http://127.0.0.1:<port>/identitytoolkit.googleapis.com/v1` or `https://identitytoolkit.googleapis.com/v1`) and `AUTH_API_KEY` |
| Ready | `GET <health_path>` → 200 within `start_timeout_seconds` |
| Logs | stdout/stderr → `runs/<run>/backend.log`; print **one JSON line per request** containing `"testId":"<X-E2E-Test-Id>"` so the harness can slice a per-test `backend.log` (R13) |
| Stop | SIGTERM, then SIGKILL after 5 s |
| Death | if the process exits on its own, the run aborts with exit 2 and a complete bundle |

## 3.2 Test-only endpoints (enabled only under `E2E_TEST_MODE=1`)

| Endpoint | Body | Effect |
|---|---|---|
| `POST /test/seed` | `{"email","profile","data"}` | apply seed `data` (a profile file's JSON object) to that account |
| `POST /test/reset/user` | `{"email"}` | account-level reset: delete everything the account owns (R9b) |
| `POST /test/reset` | — | wipe everything |

Return 200 `{"ok":true}`; return **403 when test mode is off** — the
production entrypoint must never set `E2E_TEST_MODE`. Paths are
configurable (`backend.seed_path`, …). The `data` shape is *your* contract
with your seed files; document it in `seeds/README.md`.

With `firebase.mode: none` there are no users, so the harness never calls
`/test/seed` or `/test/reset/user` (a manifest `seed:` entry is rejected
at run start). Implement them anyway if your app has its own notion of an
account; otherwise `/test/reset` alone is enough.

## 3.3 Authentication (if the app signs in)

Accept `Authorization: Bearer <Firebase ID token>`. The simplest verifier
that works against both the emulator and a real project is to POST the
token to `${AUTH_BASE_URL}/accounts:lookup?key=${AUTH_API_KEY}` and cache
the resulting `localId`/`email` per token — that is what the reference
backend does (`lib/auth.dart`). A production backend keeps its Admin-SDK
verification; only the test-mode wiring (base URL from env) is new.

Key all user data by **email** (the token proves it via `accounts:lookup`):
pool accounts are addressed by email, the harness never knows uids, and
per-test accounts are what isolate concurrently sharded tests from each
other. The harness resets every account a run uses (`/test/reset/user`)
before and after each test, so accounts can persist across runs. **No auth (`firebase.mode:
none`)?** Drop the bearer check entirely (in the starter backend: delete
`lib/auth.dart`, the `verifyToken` wiring and the `AUTH_*` env reads) and
give the feature a namespace the *test* can choose — a room, board or
list name derived from `ctx.testId` — so sharded tests still don't see
each other's data. That namespace is a legitimate app feature, not a
production-client header.

## 3.4 If the app has a backend already

- Add the three `/test/*` endpoints behind an env flag, `--port`, the
  health route, and the per-request JSON log line with the
  `X-E2E-Test-Id` header echoed. Keep the change small; it is test-only
  code.
- Set `backend.dir` / `backend.command` accordingly. Any language works.

## 3.5 If the app has no backend (or one you cannot run)

- **Starter backend**: copy `<REF>/example/backend` to `<TARGET>/backend`,
  `dart pub get`, then replace the notes/messages routes in `lib/api.dart`
  with what your app needs (keep `/health`, the `/test/*` block and the
  logging middleware; keep the auth verifier only if the app signs in —
  see 3.3 for the no-auth variant). Point the app's HTTP calls at
  `E2E_BACKEND_URL` (step 04).
- **No backend at all**: `backend.command: []`. The harness starts nothing;
  `sync.seed()` / `sync.resetAccount()` fail with a clear error; tests
  coordinate only through the sync server. Fine for single-user tests of an
  offline app; a two-user test needs *some* shared state — the starter
  backend is usually the cheapest.

## Done when

`(cd backend && E2E_TEST_MODE=1 AUTH_BASE_URL=http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1 dart run bin/server.dart --port 8099)`
answers `curl -s localhost:8099/health` with 200, `POST /test/reset`
returns `{"ok":true}`, and the same POST without `E2E_TEST_MODE` returns
403. (Stop it afterwards; the harness starts its own.)

Next: [04-app-changes.md](04-app-changes.md)
