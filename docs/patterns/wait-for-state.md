# Wait for state, never for time

**Problem.** The app polls a backend, animates, and talks to a device that
is slower on cold caches than on warm ones. Any fixed delay is either too
short (flaky) or too long (slow).

**Rule.** Every wait is *for a condition* with a *deadline*:
`waitVisible(finder, timeout: …)` for UI, `sync.waitForEvent` /
`waitForValue` / `barrier` for cross-device state, poll-with-timeout for
anything else. `pumpAndSettle` is not usable in a live app that polls on a
timer (it never settles); `Future.delayed` is banned by the integration
checker.

**Code.** `integration_test/support/wait.dart`:

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

Give `because` a sentence a human can act on ("receiver never saw sender's
message"): it becomes the failure message the audit clusters on.

**App side.** A polling widget must only `setState` when data changed;
otherwise the tree rebuilds every tick and finders race the rebuild. The
reference app's `_refresh` compares ids before calling `setState`.

**Timeouts.** UI transitions 15–30 s; backend round trips 30–60 s; the
first cross-device barrier 10 min (build skew); everything else 2 min.
