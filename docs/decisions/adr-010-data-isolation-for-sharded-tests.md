# ADR-010 (D10): Data isolation for sharded tests (2026-08-26, M2)

**Status:** accepted · 2026-08-26

## Decision

**One backend instance per run; the example backend partitions its data by the `X-E2E-Test-Id` header in test mode** (`/test/reset` with the header clears only that partition, without it clears everything)

## Rationale

R19a runs independent tests concurrently against the shared backend, so each test must see only its own data. In the example that is a header-keyed partition; in a real app the same isolation comes from per-test users (M3), which the playbook documents as the pattern. Never partition by anything a production client sends.

## Where it lives

See `refined_requirements.md` (D10) and the playbook steps that apply it.
