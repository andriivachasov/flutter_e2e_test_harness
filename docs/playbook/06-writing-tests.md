# 06 — Writing tests

## 6.1 The manifest

Tests are declared, not discovered: `<app>/integration_test/e2e_tests.yaml`.

```yaml
tests:
  - name: smoke_sign_in                      # [A-Za-z0-9_-]+, unique; = E2E_TEST_ID
    target: integration_test/smoke_sign_in_test.dart   # relative to the app dir
    tags: [smoke, single-user]               # at least one of smoke|single-user|multi-user
    roles:
      A: any                                 # role -> ios | android | any
  - name: cross_user_chat
    target: integration_test/cross_user_chat_test.dart
    tags: [smoke, multi-user]
    roles:
      A: ios
      B: android
  - name: seeded_history
    target: integration_test/seeded_history_test.dart
    tags: [single-user, seeding]
    roles: {A: any}
    seed: {A: user-with-history}             # seeds/<profile>.json, applied before the body (R8)
```

`any` roles are scheduled onto whichever device is free — that is how
independent single-user tests shard across the two devices. Multi-role
tests hold all their devices. Every role gets its own pool account
`<test name>-<role>@<email_domain>` (unless `firebase.mode: none`); add
`users: {A: chat, B: chat}` to make several tests of one feature share
accounts (`chat-a@…`, `chat-b@…`). The app registers an account the first
time it is used. Add `quarantine` to `tags` to keep a known-
flaky test visible without letting it fail the run.

## 6.2 Test skeleton

Both roles of a multi-user test run the **same file**; the role decides
the branch.

```dart
import 'package:e2e_test_support/test_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:my_app/main.dart' as app;

import 'modules/sign_in.dart';
import 'support/wait.dart';

void main() {
  patrolTest('signs in and sees home', ($) async {
    final ctx = TestContext.fromEnvironment();   // ids, role, urls, user
    final sync = SyncClient(ctx);                 // orchestrator channel
    await sync.guard(() async {                   // failure screenshot + report, then rethrow
      await sync.step('launch');                  // module boundary → timed, used for clustering
      await $.tester.pumpWidget(const app.MyApp());
      await waitVisible($, find.byKey(const Key('sign_in_page')),
          timeout: const Duration(seconds: 30));
      await sync.step('continue');
      await continueAs($, ctx);                   // a module: plain function, typed I/O
      await sync.screenshot('home');              // taken host-side into screenshots/
      expect(find.byKey(const Key('home_page')), findsOneWidget);
    });
  });
}
```

`waitVisible` is not in `test_support` (it must stay Flutter-free); copy
`<REF>/example/app/integration_test/support/wait.dart` — it pumps frames on
an interval until a finder matches or a timeout expires, which is the
live-app-safe replacement for `pumpAndSettle`:

```dart
Future<void> waitVisible(PatrolIntegrationTester $, Finder finder,
    {required Duration timeout, String? because}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await $.tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('not visible within ${timeout.inSeconds}s: $finder'
          '${because == null ? '' : ' ($because)'}');
    }
  }
}
```

## 6.3 Modules (R7)

A module is a plain Dart function with typed inputs/outputs, no globals,
in `integration_test/modules/`. It performs steps and waits for their
effects; it never provisions users, seeds data or sleeps.

```dart
class SignedInSession { const SignedInSession({required this.email, required this.uid}); final String email, uid; }

Future<AuthResult> continueAs(PatrolIntegrationTester $, TestContext ctx) async {
  if (!ctx.user.isProvisioned) fail('no pool account for role ${ctx.role}');
  await $.tester.enterText(find.byKey(const Key('email_field')), ctx.user.email);
  await $.tester.enterText(find.byKey(const Key('password_field')), ctx.user.password);
  await $.tester.tap(find.byKey(const Key('continue_button')));   // app signs in, or registers first
  await $.tester.pump();
  await waitVisible($, find.byKey(const Key('signed_in_as')), timeout: const Duration(seconds: 60));
  final registered = find.byKey(const Key('auth_mode_registered')).evaluate().isNotEmpty;
  return AuthResult(email: ctx.user.email, mode: registered ? 'registered' : 'signed-in');
}
```

Reference modules to copy/adapt: `<REF>/example/app/integration_test/modules/`
(`sign_in.dart`, `notes.dart`, `chat.dart`).

## 6.4 `TestContext` and `SyncClient`

`TestContext.fromEnvironment()` (all from the `E2E_*` defines):

| Field | Meaning |
|---|---|
| `runId`, `testId` | this run / this manifest entry — also usable as a namespace the app feature can take (room name, list name) |
| `role`, `parties` | this process's role (`A`, `B`, …) and the number of roles in the test |
| `backendUrl`, `syncUrl` | resolved for this device; `backendUrl` keeps its default when `backend.command` is `[]` |
| `user` | `email`, `password`, `scope`, `isProvisioned` — the pool account (may not exist yet; the app registers it); empty with `firebase.mode: none` |
| `authUrl`, `apiKey` | what the app signs in against |
| `runSeq` | monotonic run counter on this machine |

`SyncClient(ctx)` — the orchestrator channel:

| Call | Use |
|---|---|
| `barrier(name, {parties, timeout})` | all roles reach the same point; parties defaults to `ctx.parties` |
| `emit(name, [data])` / `waitForEvent(name, {timeout})` | one role signals, others wait |
| `put(key, value)` / `waitForValue(key, {timeout})` | cross-device handoff (e.g. exchange emails) |
| `screenshot(label)` | host-side screenshot into `screenshots/NN_label.png`; never throws |
| `step(name)` | module boundary (timings, failure clustering); never throws |
| `guard(body)` | failure report + failure screenshot + rethrow; also what releases partner roles (R25) |
| `seed(profile)` / `resetAccount()` | mid-test seeding / account-level reset via the backend's test endpoints |

Namespaced per run+test, so concurrent tests never see each other's
barriers. Every wait also ends early with `PartnerFailure` if a *different*
role in the same test fails, so a red multi-device test reports the role
that broke instead of a partner's timeout — on by default, opt out with
`sync.failFast = false` or `failFast: false` on one wait. Patterns:
[../patterns/multi-user-sync.md](../patterns/multi-user-sync.md).

## 6.5 A two-user test, minimal shape

(With `firebase.mode: none` there is no `ctx.user.email` to hand off — put
whatever identifies the role in *your* app instead, e.g. the display name
`user-${ctx.role}` typed into a field, or a room name from `ctx.testId`.)

```dart
await sync.step('launch'); /* pump app, sign in */
await sync.put('email/${ctx.role}', ctx.user.email);
final partner = await sync.waitForValue('email/${ctx.role == 'A' ? 'B' : 'A'}',
    timeout: const Duration(minutes: 10)) as String;   // absorbs build skew
await sync.barrier('app-ready', timeout: const Duration(minutes: 10));  // do not shorten
if (ctx.role == 'A') {
  await sendMessage($, partner, 'hello from A');
  await sync.emit('a-sent');
  await waitForMessage($, 'hi from B');
} else {
  await sync.waitForEvent('a-sent', timeout: const Duration(minutes: 2));
  await waitForMessage($, 'hello from A');
  await sendMessage($, partner, 'hi from B');
}
await sync.barrier('done', timeout: const Duration(minutes: 2));  // neither app torn down early
```

## 6.6 Seeds and resets

`seeds/<profile>.json` is a JSON object in your backend's seed format.
Declare it in the manifest (`seed: {A: profile}`) for preconditions; call
`sync.seed('profile')` mid-test; call `sync.resetAccount()` to wipe the
user server-side and assert the UI empties. Pattern and rules:
[../patterns/seeding-and-reset.md](../patterns/seeding-and-reset.md).

## 6.7 Rules

- Never `sleep()` / `Future.delayed` to coordinate. Wait for state or use
  the sync primitives. The integration checker greps for it.
- Screenshots at verification points (`sync.screenshot`) — cheap and the
  first thing anyone looks at.
- Asserting text inside a *keyed* `Text` widget: `find.descendant(of:
  byKey, matching: find.text(..))` excludes the root — use
  `matchRoot: true`, or assert `find.text(..)` directly. `descendant` is for
  containers (lists).
- Keep the first barrier's timeout long (10 min): cold caches build one
  platform much slower than the other. Long timeouts no longer cost you a
  slow red run — a partner's *failure* releases the wait immediately (R25);
  the timeout is only reached when nobody failed and nobody arrived.
- One test = one manifest entry = one file; share behaviour through
  modules, not through inheritance or globals.

## Done when

`e2e list` prints your tests with the expected tags and roles, and the
suite contains at least one `smoke`, one `single-user` and one
`multi-user` test.

Next: [07-run-and-verify.md](07-run-and-verify.md)
