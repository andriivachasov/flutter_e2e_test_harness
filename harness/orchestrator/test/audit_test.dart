import 'package:e2e_orchestrator/src/audit/audit.dart';
import 'package:test/test.dart';

Map<String, dynamic> run(
  String id, {
  required Map<String, ({bool passed, String? step, String? message, int ms, bool quarantined})> tests,
  int durationMs = 150000,
}) =>
    {
      'runId': id,
      'durationMs': durationMs,
      'timings': {
        'backendStartMs': 600,
        'authEmulatorStartMs': 2000,
        'provisionerPrepareMs': 10,
        'deviceBootMs': {'ios': 200, 'android': 60},
      },
      'tests': [
        for (final e in tests.entries)
          {
            'name': e.key,
            'passed': e.value.passed,
            'quarantined': e.value.quarantined,
            'infraError': null,
            'durationMs': e.value.ms,
            'provisionMs': 5,
            'roles': [
              {
                'role': 'A',
                'passed': e.value.passed,
                'verdict': e.value.passed ? 'PASS' : 'FAIL',
                'failedStep': e.value.step,
                'failureMessage': e.value.message,
                'appLaunchMs': 12000,
                'steps': [
                  {'name': 'launch', 'durationMs': 3000},
                  {'name': 'sign-in', 'durationMs': 4000 + e.value.ms % 7},
                ],
              },
            ],
          },
      ],
    };

void main() {
  test('percentile is nearest-rank', () {
    expect(percentile([], 50), isNull);
    expect(percentile([5], 95), 5);
    expect(percentile([1, 2, 3, 4, 5], 50), 3);
    expect(percentile([1, 2, 3, 4, 5], 95), 5);
    expect(percentile([10, 20, 30, 40], 50), 20);
  });

  test('normalizeMessage collapses volatile parts', () {
    expect(
      normalizeMessage('Expected: true\n  Actual: <false>\ninjected flake: run seq 3 is odd\n#0      main (file.dart:12:3)\n#1 x'),
      'Expected: true Actual: <false> injected flake: run seq # is odd',
    );
    expect(
      normalizeMessage('not visible within 60s: key (run 2026-08-26)'),
      'not visible within #s: key (run #-#-#)',
    );
  });

  test('clusters consistent-step failures, marks scattered ones, honours '
      'quarantine and suggests candidates', () {
    final summaries = [
      run('r1', tests: {
        'stable': (passed: true, step: null, message: null, ms: 30000, quarantined: false),
        'consistent': (passed: false, step: 'assert', message: 'boom 1', ms: 40000, quarantined: false),
        'scattered': (passed: false, step: 'launch', message: 'timeout 9s', ms: 50000, quarantined: false),
        'quarantined': (passed: false, step: 'x', message: 'y', ms: 20000, quarantined: true),
      }),
      run('r2', tests: {
        'stable': (passed: true, step: null, message: null, ms: 32000, quarantined: false),
        'consistent': (passed: false, step: 'assert', message: 'boom 2', ms: 41000, quarantined: false),
        'scattered': (passed: false, step: 'sign-in', message: 'INVALID_PASSWORD', ms: 52000, quarantined: false),
        'quarantined': (passed: true, step: null, message: null, ms: 21000, quarantined: true),
      }),
      run('r3', tests: {
        'stable': (passed: true, step: null, message: null, ms: 31000, quarantined: false),
        'consistent': (passed: true, step: null, message: null, ms: 39000, quarantined: false),
        'scattered': (passed: true, step: null, message: null, ms: 49000, quarantined: false),
        'quarantined': (passed: true, step: null, message: null, ms: 22000, quarantined: true),
      }),
    ];
    final report = buildAuditReport(
      auditId: 'a',
      startedAt: DateTime.now(),
      summaries: summaries,
      quarantineTag: 'quarantine',
    );
    final tests = {
      for (final t in (report['tests'] as List).cast<Map<String, Object?>>())
        t['name'] as String: t,
    };

    expect(tests['stable']!['verdict'], 'stable');
    expect(tests['stable']!['passRate'], 1.0);
    expect((tests['stable']!['durationMs'] as Map)['p50'], 31000);
    expect(tests['stable']!['suggestQuarantine'], false);

    final consistent = tests['consistent']!;
    expect(consistent['verdict'], 'consistent-step');
    final cluster = (consistent['clusters'] as List).first as Map<String, Object?>;
    expect(cluster['step'], 'assert');
    expect(cluster['message'], 'boom #'); // numbers normalized → one cluster
    expect(cluster['count'], 2);
    expect(consistent['suggestQuarantine'], true);

    expect(tests['scattered']!['verdict'], 'scattered');
    expect((tests['scattered']!['clusters'] as List), hasLength(2));

    expect(tests['quarantined']!['quarantined'], true);
    expect(tests['quarantined']!['verdict'], 'single-failure');
    expect(tests['quarantined']!['suggestQuarantine'], false);

    expect(report['quarantineSuggestion'], ['consistent', 'scattered']);
    final phases = report['phases'] as Map<String, Object?>;
    expect((phases['deviceBootMsP50'] as Map)['ios'], 200);
    expect((phases['runDurationMs'] as Map)['p50'], 150000);
    expect(((tests['stable']!['steps'] as Map)['A/launch'] as Map)['p50'], 3000);
    expect(tests['stable']!['appLaunchMsP50'], 12000);

    expect(renderTable(report), contains('consistent-step'));
    expect(renderTable(report), contains('quarantine suggestion'));
  });
}
