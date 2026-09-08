# e2e harness — documentation

Plain markdown, relative links only (open this folder as an Obsidian vault
if you like; nothing here needs Obsidian). Written for an **AI agent** that
has to integrate the harness into a Flutter app it has never seen; humans
are welcome.

| Read this when… | Go to |
|---|---|
| you are integrating the harness into an app | [playbook/00-overview.md](playbook/00-overview.md) — then follow the numbered steps |
| you want to know whether an integration is complete | [playbook/08-definition-of-integrated.md](playbook/08-definition-of-integrated.md) + `bash harness/tools/check_integration.sh` |
| a test needs to wait for something, coordinate two devices, seed data, reset state | [patterns/](patterns/README.md) |
| you want to know *why* the harness is shaped like this | [decisions/](decisions/README.md) (ADR-001 … ADR-025) |
| something is red | [troubleshooting.md](troubleshooting.md) |
| you already integrated the harness and want a newer version of it | [playbook/09-upgrading.md](playbook/09-upgrading.md) + [../CHANGELOG.md](../CHANGELOG.md) |
| you maintain the reference repo and are cutting a version | [releasing.md](releasing.md) |

## The one-paragraph version

The harness is a Dart CLI (`harness/orchestrator`, command `e2e`) plus a
zero-dependency Dart package your tests import (`harness/test_support`).
`e2e run` boots one iOS simulator and one Android emulator, starts your
backend in test mode (and a Firebase Auth emulator if your app signs in),
provisions a fresh test user per test role, seeds data, wipes the app on
the device, runs Patrol tests — one process per device, coordinated through
a sync server (barriers, events, key/value) — and writes a browsable
artifact bundle per run (`summary.html`, `summary.json`, video,
screenshots, app/test/backend logs). `e2e audit --runs N` tells you which
tests are flaky and where the time goes. Tests are declared in a YAML
manifest, written as plain Dart functions, and never sleep.

## Layout of the reference repository

The reference repository lives at
`https://github.com/andriivachasov/flutter_e2e_test_harness.git`
(https://github.com/andriivachasov/flutter_e2e_test_harness). Clone it and
copy pieces out of it into the app repo you're integrating — see
[playbook/02-vendor-the-harness.md](playbook/02-vendor-the-harness.md) §2.1
for the exact commands. It is never a git submodule, subtree, or remote of
the target repo; treat it purely as a source to copy from.

```
harness/orchestrator/   the e2e CLI (vendor this)
harness/test_support/   TestContext + SyncClient for your tests (vendor this)
harness/tools/          patrol_bootstrap.sh, check_integration.sh (vendor this)
example/app|backend|seeds   the reference app — copy pieces as templates
e2e.yaml                harness configuration (one per repo, at the root)
docs/                   this documentation
harness/VERSION         the harness version (vendor this; absent == 1.0.0)
CHANGELOG.md            one section per version, each with a Migration subsection
```
