# ADR-004 (D4): Knowledge base tooling

**Status:** accepted · 2026-08-26

## Decision

**Plain markdown in-repo, Obsidian-compatible**

## Rationale

The docs are consumed by AI agents inside a repo; versioning with code beats an external app. Use plain relative links (no wikilinks) so Obsidian can open the folder as a vault for human browsing — zero dependency, full compatibility. Obsidian is *not* a build/runtime dependency.

## Where it lives

See `refined_requirements.md` (D4) and the playbook steps that apply it.
