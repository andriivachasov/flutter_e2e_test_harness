# ADR-023 (D23): Admin-free fixed user pool (2026-08-27; supersedes D12, D17, amends D11/D14)

**Status:** accepted · 2026-08-26

## Decision

**The harness needs no Firebase admin credentials. Test users are a fixed, deterministic pool: `<scope>-<role>@<email_domain>` with one shared `provisioner.pool_password`; scope = the test name by default (own account per test role) or the manifest's `users: {role: label}` override (feature-shared accounts). The APP brings accounts into existence through its regular sign-up flow — "Continue" signs in, or registers when the email is unknown — and the harness never calls Firebase Auth. Real mode needs only `project_id` + Web `api_key` (public identifiers). The backend keys all data by the token's EMAIL, so seeding and account resets need no uid; every account a run uses is reset server-side before and after each test. Parallel runs against one real project share the pool: one run per project at a time.** Removed: service-account key, `googleapis_auth`, marker leases/TTL/heartbeat, `e2e pool`, `e2e register-app`, the stale-lease DoD

## Rationale

No secret of any kind on the orchestrator side; no lease races (D12's measured caveat disappears with the mechanism); the sign-up path is exercised by the suite itself (`returning_user` asserts register → sign-out → sign-in). Doctor probes the real project's key and email/password provider through the client API with a canary sign-in.

## Where it lives

See `refined_requirements.md` (D23) and the playbook steps that apply it.
