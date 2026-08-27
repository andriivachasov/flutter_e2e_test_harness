import 'dart:io';

import 'package:e2e_orchestrator/src/artifacts/retention.dart';
import 'package:e2e_orchestrator/src/audit/history.dart';
import 'package:test/test.dart';

Map<String, Object?> entry(
  String id, {
  required Map<String, ({double rate, String verdict, int p50, bool q})> tests,
  int runP50 = 200000,
}) =>
    {
      'auditId': id,
      'finishedAt': '2026-08-27T00:00:00Z',
      'runCount': 5,
      'meta': {'host': 'h', 'firebaseMode': 'emulator'},
      'phases': {'runP50Ms': runP50, 'runP95Ms': runP50 + 1000},
      'tests': [
        for (final e in tests.entries)
          {
            'name': e.key,
            'runs': 5,
            'passed': (e.value.rate * 5).round(),
            'passRate': e.value.rate,
            'verdict': e.value.verdict,
            'quarantined': e.value.q,
            'p50Ms': e.value.p50,
            'p95Ms': e.value.p50 + 500,
            'topCluster': e.value.verdict == 'stable'
                ? null
                : {'step': 'assert', 'message': 'boom', 'count': 2},
          },
      ],
    };

void main() {
  test('diffEntries flags regressions, improvements and suite changes', () {
    final before = entry('audit_2026-08-27T1000', tests: {
      'a': (rate: 1.0, verdict: 'stable', p50: 30000, q: false),
      'b': (rate: 0.6, verdict: 'scattered', p50: 40000, q: false),
      'gone': (rate: 1.0, verdict: 'stable', p50: 10000, q: false),
      'slow': (rate: 1.0, verdict: 'stable', p50: 10000, q: false),
    });
    final after = entry('audit_2026-08-27T1100', tests: {
      'a': (rate: 0.6, verdict: 'consistent-step', p50: 30000, q: false),
      'b': (rate: 1.0, verdict: 'stable', p50: 40000, q: true),
      'new': (rate: 1.0, verdict: 'stable', p50: 5000, q: false),
      'slow': (rate: 1.0, verdict: 'stable', p50: 15000, q: false),
    }, runP50: 260000);
    final d = diffEntries(before, after);
    expect(d['regressions'], containsAll([
      contains('`a`: 100% → 60%, stable → consistent-step (at "assert")'),
      contains('`slow`: p50 10.0s → 15.0s (+50%)'),
      contains('suite run p50 200.0s → 260.0s (+30%)'),
    ]));
    expect(d['improvements'], [contains('`b`: 60% → 100%, scattered → stable')]);
    expect(d['changes'], containsAll([
      contains('new test `new`'),
      contains('`b` quarantined'),
      contains('test `gone` no longer in the suite'),
    ]));
    expect(diffEntries(null, after)['regressions'], isEmpty);

    // A partial audit never reports membership or suite-time changes.
    final partial = entry('audit_2026-08-27T1200', tests: {
      'a': (rate: 1.0, verdict: 'stable', p50: 30000, q: false),
    }, runP50: 60000);
    (partial['meta'] as Map<String, Object?>)['selection'] = 'a';
    final pd = diffEntries(after, partial);
    expect(pd['changes'], [contains('partial audit (a)')]);
    expect(pd['regressions'], isEmpty);
    expect(pd['improvements'], [contains('`a`: 60% → 100%')]);
  });

  test('entries persist per audit, render deterministically, prune by count', () {
    final dir = Directory.systemTemp.createTempSync('e2e_hist');
    addTearDown(() => dir.deleteSync(recursive: true));
    writeHistoryEntry(dir, entry('audit_2026-08-27T1000', tests: {
      'a': (rate: 1.0, verdict: 'stable', p50: 30000, q: false),
    }));
    writeHistoryEntry(dir, entry('audit_2026-08-27T1100', tests: {
      'a': (rate: 0.8, verdict: 'single-failure', p50: 31000, q: false),
    }));
    expect(loadHistory(dir).map((e) => e['auditId']),
        ['audit_2026-08-27T1000', 'audit_2026-08-27T1100']);
    final doc1 = writeHistoryDocument(dir).readAsStringSync();
    final doc2 = writeHistoryDocument(dir).readAsStringSync();
    expect(doc1, doc2, reason: 'deterministic');
    expect(doc1, contains('## Latest: audit_2026-08-27T1100'));
    expect(doc1, contains('Regressions'));
    expect(doc1, contains('| `a` | ✅ 100% 30.0s | ❔ 80% 31.0s |'));
    expect(doc1, contains('run `e2e history` to regenerate'));

    // Audit directories are pruned like runs; entries are not touched.
    final runs = Directory('${dir.path}/runs')..createSync();
    for (final n in ['audit_2026-08-27T1000', 'audit_2026-08-27T1100', 'audit_2026-08-27T1200', '2026-08-27T1000_1']) {
      Directory('${runs.path}/$n').createSync();
    }
    final removed = pruneAudits(runs, keep: 2);
    expect(removed.single, endsWith('audit_2026-08-27T1000'));
    expect(Directory('${runs.path}/2026-08-27T1000_1').existsSync(), isTrue);
    expect(loadHistory(dir), hasLength(2));
  });
}
