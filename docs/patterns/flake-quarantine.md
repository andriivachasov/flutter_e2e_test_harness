# Flake quarantine and the audit

**Audit.** `e2e audit --runs N` repeats the suite and reports per test:
pass rate, p50/p95, per-step timings, and failure clusters keyed by
(failing step, message with numbers collapsed). Verdicts:

| Verdict | Meaning | Do |
|---|---|---|
| `stable` | passed every run | nothing |
| `consistent-step` | ≥ 75 % of failures at one step with one message | likely a product bug (or a real race) — fix the app, not the test |
| `scattered` | failures spread over steps/messages | likely infra flake — look at devices, timeouts, waits |
| `single-failure` | one failure in N | inconclusive; rerun with more `--runs` |
| `infra` | run could not execute the test | doctor, devices, backend |

**Quarantine.** Add the `quarantine` tag (`run.quarantine_tag`) to a test
that is flaky but must stay visible:

```yaml
- name: flaky_thing
  target: integration_test/flaky_thing_test.dart
  tags: [single-user, quarantine]
  roles: {A: any}
```

It still runs and appears in `summary.html` (`QUARANTINED FAIL`, a run
warning, `counts.quarantinedFailed`) but never changes the exit code. The
audit lists candidates (`quarantineSuggestion`) and never re-suggests
tests already tagged. Remove the tag when the audit shows it `stable`
again.

**Memory.** Every audit leaves `e2e-history/<auditId>.json` and
regenerates `e2e-history/HISTORY.md` (trend per test, regressions since
the previous audit). Read HISTORY.md before deciding what to quarantine
or un-quarantine; it shows whether a test got worse or better over time.

**Steps make clustering work.** `sync.step('name')` at every module
boundary; without it the audit can only cluster by message.
