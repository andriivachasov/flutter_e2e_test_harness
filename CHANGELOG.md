# Changelog

The current version is in [`harness/VERSION`](harness/VERSION) — it travels
with the vendored copy, so an integrated app always knows what it is on. **A
vendored harness with no `harness/VERSION` file is `1.0.0`.**

Every released version has exactly one section here, newest first, and every
section carries a **Migration** subsection — even when it reads "None." An
empty migration means there is nothing to do; it never means nobody wrote it
down. A missing section means that version was never released.

Versions are semantic, judged from the perspective of **an app that has
already vendored the harness**:

| Bump | Means | Migration typically says |
|---|---|---|
| **MAJOR** | The integrated app must change something or it breaks: `e2e.yaml` schema, the backend `/test/*` contract, a removed `test_support` API, a renamed manifest key | Required steps, in order |
| **MINOR** | New capability, backward compatible. Existing integrations keep working untouched | Optional steps, or "None" |
| **PATCH** | Bugfix or docs; nothing integration-facing changed | "None" |

**Upgrading a vendored copy:** follow
[docs/playbook/09-upgrading.md](docs/playbook/09-upgrading.md) — apply every
section between your `harness/VERSION` and your target **in order**
(1.0 → 1.1 → 1.2 → …), never jumping straight to the newest. Skipping a
section is how a required step goes missing.

**Releasing (maintainers):** [docs/releasing.md](docs/releasing.md).

---

## 1.0.0 — 2026-08-27

Baseline. Everything shipped through milestones M1–M5 is this version: the
`e2e` orchestrator CLI (`doctor` · `run` · `audit` · `history` · `list` ·
`devices` · `prune`), the zero-dependency `test_support` package, the Patrol
executor, the sync server, the admin-free fixed user pool (D23), artifact
retention and audit memory (D24), the integration playbook, and
`harness/tools/{patrol_bootstrap,check_integration}.sh`.

### Added

- `harness/VERSION` and this changelog: the harness is now versioned, and a
  vendored copy carries its version with it.
- [`docs/releasing.md`](docs/releasing.md) — the release process: every change
  on `dev` bumps `VERSION` and writes its own section here; `dev` → `main` is
  a plain merge with no ceremony attached.
- [`docs/playbook/09-upgrading.md`](docs/playbook/09-upgrading.md) — how an
  integrated app moves from one harness version to a newer one.

### Migration

None — this is the baseline. Any harness copy vendored before this release
is `1.0.0` and needs no changes; write `1.0.0` into its `harness/VERSION` (or
copy the file from the reference repo) so the next upgrade has a starting
point.
