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

**Failure.** `SyncTimeout('barrier "app-ready": needed 2 parties within
600s (role=B)')` in `test.log` means the other role never got there — look
at *its* screenshots/logs first.
