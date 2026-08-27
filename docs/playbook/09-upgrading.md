# 09 — Upgrading a vendored harness

Not part of a first integration — steps 00–08 cover that. Come here when the
harness in your repo is older than the reference repository and you want the
newer one.

Handing this to an agent? The reference repo's `README.md` has a
copy-pasteable **Update prompt** that drives this whole file; it works
without being told which version the app is on.

## 9.1 Find the version you are on

```sh
cat harness/VERSION        # in YOUR repo, not the reference clone
```

**No such file? You are on `1.0.0`.** That is the definition, not a guess:
`harness/VERSION` was introduced *as* 1.0.0, so every copy vendored before it
existed is 1.0.0 by construction.

## 9.2 Read the chain before touching anything

```sh
REF=/tmp/flutter_e2e_test_harness
rm -rf "$REF"
git clone --depth 1 git@github.com:andriivachasov/flutter_e2e_test_harness.git "$REF"
cat "$REF/harness/VERSION"     # the version you would be moving to
sed -n '/^## /,$p' "$REF/CHANGELOG.md"
```

In `$REF/CHANGELOG.md`, find every section **above** your current version, up
to and including your target. Those are the versions you are crossing.

**Apply them in order — 1.0 → 1.1 → 1.2 → 1.3 …, never straight from 1.0 to
1.5.** Each section's steps assume the previous section's have been applied,
so a combined jump is not the same thing as the chain and can silently skip a
required step. Sections whose Migration reads "None" still count as crossed;
read them, do nothing, move on.

Write the list down before you start — the versions you are crossing and,
for each, whether its migration is empty or has steps. That list is the plan
for 9.4.

## 9.3 Replace the code

The *code* is one wholesale copy, regardless of how many versions you are
crossing:

```sh
# from your repo root
cp -R "$REF"/harness/orchestrator "$REF"/harness/test_support \
      "$REF"/harness/tools "$REF"/harness/VERSION harness/
rm -rf harness/orchestrator/.dart_tool harness/test_support/.dart_tool
(cd harness/orchestrator && dart pub get)
(cd harness/test_support && dart pub get)
```

Two cautions:

- **Diff before you overwrite** if the target repo has app-specific edits
  inside `harness/` (commonly `harness/tools/*.sh` tweaked for this app's
  package name). `git diff` after the copy is the cheapest way to see what
  you just lost — inspect it before committing.
- Copy `"$REF"/docs` over your vendored docs copy (`docs/e2e-harness/` or
  wherever step 02 put it) in the same commit, so the playbook in your repo
  matches the code in your repo.

Copying `harness/VERSION` is what records the upgrade. If you skip everything
else in this step, do not skip that file — an inaccurate version makes the
*next* upgrade start from the wrong place.

## 9.4 Apply each version's migration, in order

Work the list from 9.2 top to bottom. The migrations touch things a wholesale
copy cannot: `e2e.yaml` keys, your backend's `/test/*` endpoints, your test
files' use of `test_support`, the manifest schema, native entry points.

Commit after each version's steps if the chain is long — a failed
`e2e doctor` then points at one version's changes instead of five.

## 9.5 Verify

```sh
cd harness/orchestrator && dart run bin/e2e.dart doctor
bash harness/tools/check_integration.sh
cd harness/orchestrator && dart run bin/e2e.dart run && dart run bin/e2e.dart run
```

Same bar as step 08: doctor all-ok, the checker's criteria all met, two
consecutive runs exit 0. A failure here is far more likely to be a missed
migration step than a harness bug — re-read the sections you crossed before
digging into `test.log`.

If a run fails on a *build* rather than a test, check the environment first:
findings about native entry points, stale Swift package references and
missing `google-services.json` all surface inside
`runs/<id>/<test>/<role>/test.log` and all read like test failures at a
glance. See [troubleshooting.md](../troubleshooting.md).

## Done when

- `harness/VERSION` in your repo matches the version you targeted
- every changelog section you crossed has had its migration applied (or was
  "None")
- `e2e doctor`, `check_integration.sh` and two consecutive `e2e run`s are
  green

Back to [08-definition-of-integrated.md](08-definition-of-integrated.md) for
the full criteria, or [00-overview.md](00-overview.md).
