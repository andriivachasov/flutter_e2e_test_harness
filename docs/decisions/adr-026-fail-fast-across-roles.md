# ADR-026 (D26): Fail-fast across roles (2026-08-27)

**Status:** accepted · 2026-08-26

## Decision

**A role's failure is published to its test's namespace on the sync server by `SyncClient.guard`'s single wrapping `catch` (before the failure screenshot, which can take tens of seconds). The three waiters (`barrier`, `waitForEvent`, `waitForValue`) read a `failed: {role, message}` field the server attaches to the poll response they were already making, and throw `PartnerFailure` — a distinct type from `SyncTimeout` — naming the failing role. First failure per test wins, so a cascade never rewrites the cause; a role is never released by its own failure; data that has already arrived still wins over the marker. Default on, opt out with `sync.failFast = false` or `failFast: false` on one wait**

## Rationale

Without it a partner polls to its own deadline (5–10 min, sized for build skew) and then reports a timeout against *itself*, so a red multi-device run costs a full wait budget and names the wrong side first. Publishing from the one wrapping catch — rather than per step — is what removes the early-failure race instead of shrinking it: there is no window where the body has failed and partners have not been told. Riding the existing poll keeps it at one request per iteration, and an absent field simply means today's behaviour, so a client and server vendored at different versions degrade gracefully in both directions.

## Where it lives

See `refined_requirements.md` (D26) and the playbook steps that apply it.
