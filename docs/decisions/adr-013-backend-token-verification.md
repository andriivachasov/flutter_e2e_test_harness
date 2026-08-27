# ADR-013 (D13): Backend token verification (2026-08-26, M3)

**Status:** accepted · 2026-08-26

## Decision

**The example backend verifies bearer ID tokens by calling Identity Toolkit `accounts:lookup` with the token** (cached per token), against the emulator or the real project depending on `AUTH_BASE_URL`

## Rationale

One code path, zero JWT/RSA code in a Dart example. A production backend verifies signatures locally (Firebase Admin SDK); the playbook documents that swap — the harness contract (bearer token in, uid out) is unchanged.

## Where it lives

See `refined_requirements.md` (D13) and the playbook steps that apply it.
