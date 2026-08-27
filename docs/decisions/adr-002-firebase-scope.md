# ADR-002 (D2): Firebase scope

**Status:** accepted · 2026-08-26

## Decision

**Emulator-first, design for real**

## Rationale

Local runs use Firebase Emulator Suite (Auth). The user-provisioning layer is abstracted so the same tests can later run against a real/staging Firebase project. Both strategies (fresh-user and pooled) get implemented, not just documented.

## Where it lives

See `refined_requirements.md` (D2) and the playbook steps that apply it.
