# ADR-025 (D25): Release strategy and versioned migrations (2026-08-27)

**Status:** accepted · 2026-08-26

## Decision

**The harness carries a semver `harness/VERSION` inside the vendored tree (absent == `1.0.0`) and a root `CHANGELOG.md` with one section per version, each containing a `Migration` subsection that is written even when empty. Work lands on `dev`, where every change bumps `VERSION` and adds its changelog section in the same commit and is tagged `v<version>`; `dev` → `main` is a plain merge with no version ceremony, so `main` may advance several versions at once. An integrated app upgrades by walking every intervening section in order (1.0 → 1.1 → 1.2 …), never jumping straight to the newest**

## Rationale

The harness is vendored, not depended on: nothing pulls updates for an integrated app, so the version file plus the changelog *are* the upgrade mechanism. Bumping per change on `dev` rather than per release removes the release ritual entirely (the merge is just a merge) at the cost of requiring the discipline on every change; a mandatory-but-possibly-empty migration section makes "nothing to do" distinguishable from "nobody wrote it down", which is what makes an ordered walk trustworthy.

## Where it lives

See `refined_requirements.md` (D25) and the playbook steps that apply it.
