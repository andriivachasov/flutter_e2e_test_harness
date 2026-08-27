# ADR-012 (D12): Pooled-lease storage (2026-08-26, M3) — **superseded by D23**

**Status:** accepted · 2026-08-26

## Decision

**A lease on pool slot N is a *marker* Auth user `lease.<prefix>N@<domain>`.** Firebase Auth rejects a create for an existing email (`EMAIL_EXISTS`), so non-overlapping contenders exclude each other across processes and machines. *Measured caveat (2026-08-26, real project): creates in flight at the same instant can all succeed — the uniqueness check is read-then-write — so after creating its marker a contender settles (1.5 s), re-reads all accounts with that email and yields unless its marker is the oldest (ties: lowest uid); losers delete theirs. Acquires within one process are serialized outright.* The marker's `displayName` carries `{owner, expiresAt, host, pid}`; holders heartbeat it; anyone may reclaim a marker whose `expiresAt` has passed. On every acquire the pool account gets a fresh password and its sessions are revoked

## Rationale

Concurrency-safe leasing with stale-lease recovery (R10) using only the Auth API the harness already needs — no Firestore, no lock files, no extra datastore to provision or clean. Leases are visible in the Firebase console and via `e2e pool`. Residual risk: two *different machines* creating the same marker within the same ~100 ms and both reading before the other's write is visible; the TTL bounds the damage and the audit (M4) would show it as a sign-in failure.

## Where it lives

See `refined_requirements.md` (D12) and the playbook steps that apply it.
