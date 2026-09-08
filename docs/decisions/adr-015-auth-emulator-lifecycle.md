# ADR-015 (D15): Auth emulator lifecycle (2026-08-26, M3)

**Status:** accepted · 2026-08-26

## Decision

**One Auth emulator per run, started by the orchestrator through the `firebase` CLI with a per-run `firebase.json` whose ports (auth, hub, logging) come from the port allocator; only the Auth emulator is started.** Installed via `brew install firebase-cli` (`setup/step4_firebase.sh`)

## Rationale

Parallel runs never collide (R19); the Auth emulator lives inside the CLI, so no Java runtime is needed; `firebase.log` lands in the run's artifact bundle (R12).

## Where it lives

See `refined_requirements.md` (D15) and the playbook steps that apply it.
