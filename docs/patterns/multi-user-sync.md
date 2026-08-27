# Multi-user synchronization

**Problem.** "User A sends, user B receives" runs as two Patrol processes
on two devices. Their timing is unrelated; the assertion must be
deterministic.

**Mechanism.** The orchestrator runs a sync server; `SyncClient(ctx)` in
`e2e_test_support` talks to it over plain HTTP polling, namespaced by run
and test so concurrent tests never collide. Primitives:

| Primitive | Semantics |
|---|---|
| `barrier(name)` | returns when `ctx.parties` distinct roles have arrived |
| `emit(name, data)` / `waitForEvent(name)` | latch: once emitted, every waiter returns with `data` |
| `put(key, value)` / `waitForValue(key)` | latch with payload: cross-device handoff |

All waits take a `timeout` and throw `SyncTimeout` — never hang.

**Fail-fast (R25).** If another role fails, every partner's outstanding wait
ends *immediately* with `PartnerFailure`, naming the role that actually
failed and its message — instead of polling to its own deadline and throwing
a `SyncTimeout` that names the partner. This is on by default and needs no
code in the test; it works because `sync.guard(...)` publishes the failure
from the one `catch` that wraps the whole body, so even a role that dies in
its first step releases the others.

```
PartnerFailure: role "A" failed: Bad state: expected 1 message, found 0
```

Read it as: *A is the bug; B is collateral.* Go to A's screenshots and
`test.log`.

Opt out only in a test that legitimately expects a partner to fail:

```dart
sync.failFast = false;                       // whole test
await sync.barrier('done', failFast: false); // one wait
```

**Shape of a two-user test.**

```
launch + sign in                      (both roles, independently)
put('email/<role>', me) / waitForValue('email/<other>')   handoff
barrier('app-ready', 10 min)          absorb build/boot skew
A: act → emit('a-sent') → wait for B's effect
B: waitForEvent('a-sent') → wait for A's effect → act
barrier('done', 2 min)                nobody exits while the other asserts
```

**Rules.**

- Both roles run the same test file; branch on `ctx.role`. Roles are
  named in the manifest (`roles: {A: ios, B: android}`); `any` is allowed
  for roles that don't care about the platform.
- Wait for the *effect in the UI* (`waitForMessage`), not for the event
  alone — the event only says "A acted", the assertion is that B *sees* it.
- Always end with a barrier: on iOS, a finished Patrol process kills the
  app while the other role may still be asserting against the backend.
- N > 2: `parties` defaults to the manifest's role count; give each role a
  distinct name (`A`, `B`, `C`) and use `waitForValue('email/C')` etc.

**Failure.** With fail-fast on, a partner's failure surfaces as
`PartnerFailure` naming that partner — start there. A `SyncTimeout` now
means something else: the other role never *arrived* and never *failed*
either — it is still building, still booting, or its process died without
running `guard` (a build failure, a crash on launch). Look at its
`test.log` first, and at the build output before the test output.
