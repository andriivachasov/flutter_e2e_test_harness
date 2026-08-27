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

## 1.1.1 — 2026-08-27

Documentation only. Adds a copy-pasteable **Update prompt** to the reference
repo's `README.md`, next to the existing bootstrap prompt, for handing an
upgrade to an agent working inside an app that already has the harness. It
does not need to be told which version the app is on — it derives that from
`harness/VERSION` (absent = 1.0.0) and walks this changelog from there.
`playbook/09-upgrading.md` points back at it.

### Migration

None — nothing in `harness/` changed. Re-vendor only if you want the
refreshed docs.

---

## 1.1.0 — 2026-08-27

Multi-role tests now fail as soon as one role fails. Previously a partner
kept polling to its own deadline — commonly 5–10 minutes, since those waits
are sized to absorb cold-cache build skew — and then threw `SyncTimeout`
naming *itself* rather than the role that actually broke. A red two-device
run paid a full wait budget and put the misleading error first.

### Added

- `PartnerFailure` (exported from `e2e_test_support`): thrown by `barrier`,
  `waitForEvent` and `waitForValue` when a *different* role in the same test
  has failed. Carries that role's name and message, so the first error a
  reader sees is the true one. A distinct type from `SyncTimeout`, which now
  means only "nobody arrived and nobody failed" — still building, still
  booting, or a process that died without reaching `guard`.
- Opt-out for tests that legitimately expect a partner to fail:
  `sync.failFast = false` for a whole test, `failFast: false` on one wait.
- The sync server records the first failure per run+test namespace and
  attaches it as `failed: {role, message}` to the poll responses waiters
  were already making (`/sync/count`, and the 404s of `/sync/event` and
  `/sync/kv`) — one request per poll, unchanged.

### Changed

- `SyncClient.guard` reports the failure *before* taking the failure
  screenshot. The screenshot can take tens of seconds and every partner
  spends that time still waiting. Artifacts are unaffected — the screenshot
  is still taken, still before the rethrow.

### Migration

None. Existing multi-role tests get fail-fast without any change: the
signal is published by `guard`, which every test body is already wrapped in.

Two notes if you are re-vendoring:

- Re-vendor **`harness/test_support` and `harness/orchestrator` together.**
  A mismatched pair degrades gracefully rather than breaking (a new client
  against an old server never sees the field and behaves as it did in 1.0.0;
  an old client against a new server ignores it), but you only get the
  feature with both.
- A test that *expects* a partner to fail — rare, but a suite testing
  failure handling would — must now set `sync.failFast = false`, or it will
  end early with `PartnerFailure` instead of reaching its own assertion.

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
