# ADR-017 (D17): Web API key handling (2026-08-26, M3) — **superseded by D23**

**Status:** accepted · 2026-08-26

## Decision

**`firebase.api_key` is optional in real mode: the orchestrator discovers the project's Web API key from any registered app via the Firebase Management API; `e2e register-app` registers a Web app named `e2e-harness` once if the project has none**

## Rationale

The key is a public client identifier, not a secret, and the service account can read it — one less value to copy by hand into `e2e.local.yaml`.

## Where it lives

See `refined_requirements.md` (D17) and the playbook steps that apply it.
