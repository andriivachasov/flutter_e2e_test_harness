# Releasing the harness

For maintainers of the reference repository. Integrators upgrading a vendored
copy want [playbook/09-upgrading.md](playbook/09-upgrading.md) instead.

The harness is **vendored, not depended on** (playbook 02): apps copy
`harness/` into their own repo. Nothing pulls an update for them, so the
version and the changelog are the entire upgrade mechanism. They only work if
every change writes its entry when it lands — there is no batching step later
that would catch a missing one.

## Branch model

| Branch | Role |
|---|---|
| `dev` | Where work lands. **Every change bumps [`harness/VERSION`](../harness/VERSION) and adds its own section to [`CHANGELOG.md`](../CHANGELOG.md), in the same commit as the change itself.** |
| `main` | The released branch. A `dev` → `main` merge is a **plain merge** — no version bump, no changelog edit, no release ritual. `main` simply reflects whatever state `dev` was at when promoted. |

Because versions are cut on `dev`, `main` can jump several versions in one
merge (1.4 → 1.6 if two changes landed since the last promotion). That is
fine and expected: every intermediate version still has its own changelog
section, so an app upgrading from 1.4 still walks 1.4 → 1.5 → 1.6.

## Landing a change on `dev`

One commit contains all four of these:

1. The change itself.
2. **`harness/VERSION`** bumped — MAJOR / MINOR / PATCH per the table at the
   top of [`CHANGELOG.md`](../CHANGELOG.md), judged by what an app that has
   *already vendored* the harness has to do about it.
3. **A new `CHANGELOG.md` section** for that version, at the top:

   ```markdown
   ## <version> — <YYYY-MM-DD>

   <One paragraph: what changed and why, in the integrator's terms.>

   ### Added / Changed / Fixed / Removed
   <only the headings that apply>

   ### Migration

   <Required steps in order, or "None — <why>.">
   ```

   The **Migration** heading is never omitted. If there is nothing to do, say
   "None" and say why in half a line ("internal to the executor; no vendored
   file or config key changed"). An empty migration is a claim that upgrading
   is safe, which is worth stating; a *missing* one is indistinguishable from
   an oversight.
4. A tag on that commit: `git tag v<version>`, pushed with
   `git push origin v<version>`. This is what makes
   `git clone --branch v1.2.0 …` (playbook 02) pin to a real point, and what
   lets `git diff v1.4.0 v1.6.0 -- harness/` show an integrator exactly what
   moved.

If a change genuinely affects nothing an integrator sees and you do not want
to spend a version on it (a typo in a comment, a `_e2e/` note), fold it into
the next real change's commit rather than releasing a version with an empty
changelog section. Every version in `harness/VERSION` must have a section;
not every commit needs to be a version.

## Writing the migration steps

Written for an agent or a human working *in the target repo*, who has the new
`harness/` copied in and needs to know what else to touch. Be concrete:

- Name the file and the key: "`e2e.yaml`: rename `backend.reset_path` to
  `backend.reset_all_path`" — not "the reset config changed".
- Give the check that proves it worked, if one exists: "`e2e doctor` now
  fails with `unknown key: reset_path` until this is done."
- If the step is conditional, lead with the condition: "**If your backend
  verifies tokens by signature** (JWKS/OIDC): …".
- Order matters within a section. Assume the previous section's steps have
  already been applied.

## Promoting `dev` to `main`

```sh
git checkout main && git merge --ff-only dev && git push origin main
```

Nothing else. Before promoting, the suite must be green in both Firebase
modes (`dart run bin/e2e.dart run` and `E2E_FIREBASE_MODE=real …`) — the
usual bar, unchanged by any of this.

## Checklist

- [ ] `harness/VERSION` bumped, and the bump level matches what integrators
      must do
- [ ] `CHANGELOG.md` has a section for exactly that version, with a
      **Migration** subsection (possibly "None")
- [ ] Migration steps name files and keys, and are ordered
- [ ] `git tag v<version>` pushed
- [ ] Suite green in both Firebase modes before `dev` → `main`
