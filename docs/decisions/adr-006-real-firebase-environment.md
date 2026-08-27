# ADR-006 (D6): Real-Firebase environment

**Status:** accepted · 2026-08-26

## Decision

**Dedicated test-only Firebase project**

## Rationale

Pool/cleanup bugs have zero blast radius. Credentials: service-account key file, path via env var, gitignored. Pooled provisioner is fully verifiable against it.

## Where it lives

See `refined_requirements.md` (D6) and the playbook steps that apply it.
