# ADR-014 (D14): Data isolation, revised (2026-08-26, M3; amends D10)

**Status:** accepted · 2026-08-26

## Decision

**Isolation between concurrently sharded tests now comes from per-test users: every role gets its own Firebase Auth user and the backend keys all data by that user.** The `X-E2E-Test-Id` header is kept for log correlation only (R13)

## Rationale

This is the pattern real apps already have; the header partition was an M2 stop-gap for an unauthenticated app.

## Where it lives

See `refined_requirements.md` (D14) and the playbook steps that apply it.
