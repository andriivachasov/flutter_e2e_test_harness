# ADR-022 (D22): Playbook verification protocol (2026-08-26, M5)

**Status:** accepted · 2026-08-26

## Decision

**The playbook's DoD is executed by a fresh agent that receives only `docs/` and a separately created vanilla Flutter app, may copy what the playbook tells it to copy, must log every gap/source-read in `PLAYBOOK_GAPS.md`, and must reach two consecutive green `e2e run`s plus `check_integration.sh` OK. Every logged gap becomes a doc or harness fix upstream**

## Rationale

R22's "written for an AI agent" is only testable by an agent without the author's context; the gap log turns the exercise into fixes instead of a pass/fail. First exercise (2026-08-26): passed; one harness bug (doctor with `mode: none`) and ten doc gaps found and fixed.

## Where it lives

See `refined_requirements.md` (D22) and the playbook steps that apply it.
