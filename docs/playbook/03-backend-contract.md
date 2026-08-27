# 03 — Backend contract

The harness is backend-language-agnostic: it only needs HTTP/1.1 + JSON and
the small contract below. The reference backend (`<REF>/example/backend`,
Dart/shelf, ~250 lines) implements all of it and doubles as a **starter
backend** for apps that have none.

## 3.1 Process contract (harness → backend)

| What | Detail |
|---|---|
| Start | `backend.command` + `backend.port_flag` (default `--port <n>`, templated — see 3.4) in `backend.dir`; a free port per run |
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

### Lock the surface: bind to loopback

`E2E_TEST_MODE` is an **enable flag, not an authentication factor**. This
surface deletes arbitrary user data and must work *before* an account
exists, so it cannot take a bearer token — which leaves the flag as the
only gate. A test backend bound to `0.0.0.0` is therefore an
unauthenticated, network-reachable data-deletion endpoint for everyone who
can route to the host.

**Bind the test backend to `127.0.0.1`, and reject `/test/*` requests whose
remote address is not loopback.** Every legitimate caller is on this host:
the orchestrator posts to `127.0.0.1`, and both device flavours reach the
host loopback (Android emulators through the `10.0.2.2` alias, iOS
simulators directly). Loopback is a strong lock precisely because it does
not depend on what an attacker knows — there is no secret to leak, log,
copy into CI or forget to rotate. Do both halves: the bind keeps the port
off the network, and the filter still holds if someone later changes the
bind address (a container image, a `--host` flag, a framework default).
Fail **closed**: a request whose remote address is absent or unparseable is
refused, not trusted. It is a dozen lines of middleware in shelf, about
forty in a servlet filter or an equivalent — cheap, whatever the stack:

```dart
// reference backend, lib/api.dart — shelf; a servlet Filter, an ASP.NET
// middleware or a Rack middleware reads the same.
Middleware loopbackOnly({String prefix = '/test/'}) => (inner) => (req) async {
      if (!'/${req.url.path}'.startsWith(prefix)) return inner(req);
      final info = req.context['shelf.io.connection_info'];
      final remote = info is HttpConnectionInfo ? info.remoteAddress : null;
      if (remote == null || !remote.isLoopback) {          // fail closed
        return Response(403, body: '{"error":"test endpoints are loopback-only"}');
      }
      return inner(req);
    };
```

The reference backend does exactly this: `bin/server.dart` binds
`127.0.0.1` (`--host 0.0.0.0` is available for the rare case that needs it)
and the filter above guards `/test/*` whatever the bind address.

If you sit behind a proxy, trust the socket address, not
`X-Forwarded-For` — a header is caller-controlled. And if the port really
must be reachable off-host (a physical device on the LAN, a CI container
talking to a sibling service), widen the allowed addresses to exactly the
ones you must serve — and add the shared secret below, because loopback is
no longer doing the work.

### Optional second factor: `backend.test_header`

For a backend that cannot bind to loopback — or an integrator who wants a
second lock anyway — the harness can send a shared secret with every
`/test/*` request. Unset by default; configuring it changes nothing else.

```yaml
# e2e.local.yaml — gitignored: the value is a secret
backend:
  test_header:
    name: X-E2E-Test-Secret
    value: "a-long-random-string"
```

A map of `header: value` pairs works too, if you need more than one. The
value can also come from the environment
(`E2E_BACKEND_TEST_HEADER` / `E2E_BACKEND_TEST_HEADER_VALUE`), so CI never
writes it to disk. The backend side is one comparison, constant-time if
your language makes that easy:

```dart
if (secret != null && req.headers['x-e2e-test-secret'] != secret) {
  return Response(403, body: '{"error":"bad or missing test secret"}');
}
```

The harness treats the value like every other secret: it is redacted from
`summary.json`, `orchestrator.log` and `test.log`, and only the header
*name* is ever printed. Make sure your backend keeps that promise too —
log header names, never their values.

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

- Add the three `/test/*` endpoints behind an env flag, a way to pick the
  listen port from the command line, the health route, and the per-request
  JSON log line with the `X-E2E-Test-Id` header echoed. Keep the change
  small; it is test-only code.
- Add the loopback filter above with them, in the same change — an
  existing backend is the one most likely to bind to all interfaces
  already, and it is the only lock this surface has.
- Set `backend.dir` / `backend.command` accordingly. Any language works.

**Telling the backend which port to use.** The harness picks a free port
per run and appends `backend.port_flag` to `backend.command`. The default
is `["--port", "{port}"]`; every `{port}` in the template is replaced with
the run's port, and the template may be a single string or a list of
strings:

```yaml
backend:
  dir: server
  command: ["./gradlew", "bootRun"]
  port_flag: "--server.port={port}"        # Spring Boot
  # port_flag: ["-p", "{port}"]            # Rails
  # port_flag: "127.0.0.1:{port}"          # Django-style positional host:port
  # port_flag: ["--port", "{port}"]        # default
```

A template with no `{port}` in it is rejected at config load (`e2e doctor`
and every command fail with a `ConfigError`) rather than silently starting
the backend on the wrong port.

**Wrapper scripts are a first-class option.** `port_flag` removes the need
for a wrapper whose *only* job is translating a flag — but plenty of
backends need one anyway: a JVM service that must start a database
container first, resolve a JDK, export credentials, or run a migration
before the server comes up. Write `scripts/e2e-backend.sh`, have it do that
work and `exec` the real server with the arguments it was handed, and point
the harness at it:

```yaml
backend:
  dir: .
  command: ["scripts/e2e-backend.sh"]
  # port_flag defaults to ["--port", "{port}"], so the script gets
  # `--port <n>`; set it to whatever your script prefers to parse.
```

```bash
#!/usr/bin/env bash
set -euo pipefail
# 1. environment the server needs (JDK, DB, migrations)
export JAVA_HOME="$(/usr/libexec/java_home -v 21)"
docker compose up -d postgres
./gradlew flywayMigrate -q
# 2. hand the harness's arguments (E2E_TEST_MODE is already in the env)
#    straight to the real server; exec keeps SIGTERM working on stop.
exec ./gradlew bootRun --args="$*"
```

Keep the `exec`: the harness stops the backend with SIGTERM then SIGKILL,
and a non-`exec` wrapper leaves the real server orphaned.

## 3.5 If the app has no backend (or one you cannot run)

- **Starter backend**: copy `<REF>/example/backend` to `<TARGET>/backend`,
  `dart pub get`, then replace the notes/messages routes in `lib/api.dart`
  with what your app needs (keep `/health`, the `/test/*` block, the
  logging middleware and the `loopbackOnly()` filter; keep the auth
  verifier only if the app signs in —
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
403. And the surface is locked: with the server running,
`curl -s -m 3 http://$(ipconfig getifaddr en0):8099/test/reset -X POST`
(your LAN address) does **not** return `{"ok":true}` — it fails to connect
(loopback bind) or answers 403 (loopback filter). (Stop it afterwards; the
harness starts its own.)

Next: [04-app-changes.md](04-app-changes.md)
