# ADR-021 (D21): Optional Firebase and backend (2026-08-26, M5)

**Status:** accepted · 2026-08-26

## Decision

**`firebase.mode: none` (no emulator, no provisioned users, `TestContext.user` empty) and `backend.command: []` (harness starts no backend, passes no `E2E_BACKEND_URL`; seeding/account resets unavailable) are first-class configurations.** Manifest `seed:` entries are rejected at run start in either

## Rationale

The playbook must be honest for arbitrary apps: a vanilla app has neither Firebase nor a backend, and the harness (devices, sync, artifacts, audit) is still useful for it. Verified by the M5 DoD on a vanilla app with `mode: none` + a starter backend.

## Where it lives

See `refined_requirements.md` (D21) and the playbook steps that apply it.
