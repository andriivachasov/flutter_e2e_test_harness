import 'dart:convert';
import 'dart:io';

/// D24: audit memory. Every audit leaves ONE small JSON entry in the
/// history directory (`e2e-history/<auditId>.json`, committed) and the
/// trend document `HISTORY.md` is regenerated from all entries. Per-audit
/// files never collide in merges; HISTORY.md is derived and deterministic,
/// so a merge conflict on it is resolved by regenerating (`e2e history`).

/// Compact per-audit record derived from an audit report.
Map<String, Object?> historyEntryFromReport(
  Map<String, Object?> report, {
  required Map<String, Object?> meta,
}) {
  final tests = (report['tests'] as List).cast<Map<String, Object?>>();
  return {
    'auditId': report['auditId'],
    'finishedAt': report['finishedAt'],
    'runCount': report['runCount'],
    'meta': meta,
    'phases': {
      'runP50Ms': ((report['phases'] as Map)['runDurationMs'] as Map)['p50'],
      'runP95Ms': ((report['phases'] as Map)['runDurationMs'] as Map)['p95'],
    },
    'tests': [
      for (final t in tests)
        {
          'name': t['name'],
          'runs': t['runs'],
          'passed': t['passed'],
          'passRate': t['passRate'],
          'verdict': t['verdict'],
          'quarantined': t['quarantined'],
          'p50Ms': (t['durationMs'] as Map)['p50'],
          'p95Ms': (t['durationMs'] as Map)['p95'],
          'topCluster': (t['clusters'] as List).isEmpty
              ? null
              : {
                  'step': ((t['clusters'] as List).first as Map)['step'],
                  'message': ((t['clusters'] as List).first as Map)['message'],
                  'count': ((t['clusters'] as List).first as Map)['count'],
                },
        },
    ],
  };
}

/// Writes the entry file; returns it.
File writeHistoryEntry(Directory dir, Map<String, Object?> entry) {
  dir.createSync(recursive: true);
  final f = File('${dir.path}/${entry['auditId']}.json');
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(entry));
  return f;
}

/// All entries, oldest first (audit ids sort chronologically).
List<Map<String, Object?>> loadHistory(Directory dir) {
  if (!dir.existsSync()) return const [];
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'^audit_.*\.json$').hasMatch(f.uri.pathSegments.last))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final f in files)
      (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>).cast<String, Object?>(),
  ];
}

/// Rank of verdicts, worse = higher.
int verdictRank(Object? v) => switch (v) {
      'stable' => 0,
      'single-failure' => 1,
      'scattered' => 2,
      'consistent-step' => 3,
      'infra' => 4,
      _ => 1,
    };

/// What changed between the latest entry and the one before it.
/// Pure: unit-tested without a filesystem.
Map<String, List<String>> diffEntries(
  Map<String, Object?>? previous,
  Map<String, Object?> latest,
) {
  final regressions = <String>[];
  final improvements = <String>[];
  final changes = <String>[];
  Map<String, Map<String, Object?>> byName(Map<String, Object?>? e) => {
        if (e != null)
          for (final t in (e['tests'] as List).cast<Map<String, Object?>>())
            t['name'] as String: t,
      };
  final before = byName(previous);
  final after = byName(latest);
  // A partial audit (--test/--tag) says nothing about tests it did not run:
  // membership changes are only meaningful between full-suite audits.
  String selectionOf(Map<String, Object?>? e) =>
      '${((e?['meta'] as Map?)?['selection']) ?? 'all'}';
  final comparable = previous == null ||
      selectionOf(previous) == selectionOf(latest);
  if (previous != null && !comparable) {
    changes.add('partial audit (${selectionOf(latest)}) compared per test '
        'against ${previous['auditId']} (${selectionOf(previous)})');
  }
  String pct(Object? r) => '${((r as num) * 100).round()}%';
  String secs(Object? ms) => ms == null ? '-' : '${((ms as num) / 1000).toStringAsFixed(1)}s';

  for (final name in after.keys) {
    final a = after[name]!;
    final b = before[name];
    if (b == null) {
      if (comparable) {
        changes.add('new test `$name` (${a['verdict']}, ${pct(a['passRate'])})');
      }
      continue;
    }
    final rateA = (a['passRate'] as num).toDouble();
    final rateB = (b['passRate'] as num).toDouble();
    final va = verdictRank(a['verdict']);
    final vb = verdictRank(b['verdict']);
    final p50A = (a['p50Ms'] as num?)?.toDouble();
    final p50B = (b['p50Ms'] as num?)?.toDouble();
    final verdictText = a['verdict'] == b['verdict']
        ? '${a['verdict']}'
        : '${b['verdict']} → ${a['verdict']}';
    if (rateA < rateB || va > vb) {
      regressions.add('`$name`: ${pct(rateB)} → ${pct(rateA)}, $verdictText'
          '${a['topCluster'] == null ? '' : ' (at "${(a['topCluster'] as Map)['step']}")'}');
    } else if (rateA > rateB || va < vb) {
      improvements.add('`$name`: ${pct(rateB)} → ${pct(rateA)}, $verdictText');
    }
    if (p50A != null && p50B != null && p50B > 0) {
      final ratio = p50A / p50B;
      if (ratio >= 1.2) {
        regressions.add('`$name`: p50 ${secs(p50B)} → ${secs(p50A)} (+${((ratio - 1) * 100).round()}%)');
      } else if (ratio <= 0.8) {
        improvements.add('`$name`: p50 ${secs(p50B)} → ${secs(p50A)} (${((ratio - 1) * 100).round()}%)');
      }
    }
    if (a['quarantined'] != b['quarantined']) {
      changes.add('`$name` ${a['quarantined'] == true ? 'quarantined' : 'un-quarantined'}');
    }
  }
  if (comparable) {
    for (final name in before.keys.where((n) => !after.containsKey(n))) {
      changes.add('test `$name` no longer in the suite');
    }
  }
  final rp50A = ((latest['phases'] as Map)['runP50Ms'] as num?)?.toDouble();
  final rp50B = ((previous?['phases'] as Map?)?['runP50Ms'] as num?)?.toDouble();
  if (comparable && rp50A != null && rp50B != null && rp50B > 0) {
    final ratio = rp50A / rp50B;
    if (ratio >= 1.2) regressions.add('suite run p50 ${secs(rp50B)} → ${secs(rp50A)} (+${((ratio - 1) * 100).round()}%)');
    if (ratio <= 0.8) improvements.add('suite run p50 ${secs(rp50B)} → ${secs(rp50A)} (${((ratio - 1) * 100).round()}%)');
  }
  return {
    'regressions': regressions,
    'improvements': improvements,
    'changes': changes,
  };
}

/// Renders HISTORY.md from all entries (oldest first). Deterministic.
String renderHistory(List<Map<String, Object?>> entries, {int window = 10}) {
  final b = StringBuffer();
  b.writeln('# e2e history');
  b.writeln();
  b.writeln('_Generated by `e2e audit` / `e2e history` from the `audit_*.json` '
      'entries in this directory. Do not edit by hand; on a merge conflict, '
      'keep both sides\' JSON files and run `e2e history` to regenerate._');
  b.writeln();
  if (entries.isEmpty) {
    b.writeln('No audits recorded yet. Run `e2e audit --runs 5`.');
    return b.toString();
  }
  String pct(Object? r) => r == null ? '-' : '${((r as num) * 100).round()}%';
  String secs(Object? ms) => ms == null ? '-' : '${((ms as num) / 1000).toStringAsFixed(1)}s';
  String verdictMark(Object? v) => switch (v) {
        'stable' => '✅',
        'consistent-step' => '❌',
        'scattered' => '⚠️',
        'single-failure' => '❔',
        'infra' => '🛠',
        _ => '?',
      };

  final latest = entries.last;
  final previous = entries.length > 1 ? entries[entries.length - 2] : null;
  final meta = (latest['meta'] as Map?) ?? const {};
  b.writeln('## Latest: ${latest['auditId']}');
  b.writeln();
  b.writeln('${latest['finishedAt']} · ${latest['runCount']} runs · '
      'firebase ${meta['firebaseMode'] ?? '?'} · host ${meta['host'] ?? '?'}'
      '${meta['gitCommit'] == null ? '' : ' · ${meta['gitBranch'] ?? ''}@${meta['gitCommit']}'}'
      ' · suite run p50 ${secs((latest['phases'] as Map)['runP50Ms'])}');
  b.writeln();
  final diff = diffEntries(previous, latest);
  b.writeln('### Since ${previous == null ? 'the beginning' : previous['auditId']}');
  b.writeln();
  if (diff.values.every((l) => l.isEmpty)) {
    b.writeln('No change.');
  }
  for (final (title, key) in const [
    ('Regressions', 'regressions'),
    ('Improvements', 'improvements'),
    ('Suite changes', 'changes'),
  ]) {
    final items = diff[key]!;
    if (items.isEmpty) continue;
    b.writeln('**$title**');
    for (final i in items) {
      b.writeln('- $i');
    }
    b.writeln();
  }

  // Trend table: one row per test, one column per audit (last `window`).
  final recent = entries.length > window ? entries.sublist(entries.length - window) : entries;
  final names = <String>{
    for (final e in recent)
      for (final t in (e['tests'] as List).cast<Map<String, Object?>>()) t['name'] as String,
  }.toList()
    ..sort();
  b.writeln('## Trend (pass rate · p50; last ${recent.length} audits, oldest → newest)');
  b.writeln();
  b.writeln('| test | ${recent.map((e) => _shortId(e['auditId'] as String)).join(' | ')} |');
  b.writeln('|---|${recent.map((_) => '---').join('|')}|');
  for (final name in names) {
    final cells = recent.map((e) {
      final t = (e['tests'] as List)
          .cast<Map<String, Object?>>()
          .where((t) => t['name'] == name)
          .firstOrNull;
      if (t == null) return '·';
      return '${verdictMark(t['verdict'])} ${pct(t['passRate'])} ${secs(t['p50Ms'])}'
          '${t['quarantined'] == true ? ' Q' : ''}';
    });
    b.writeln('| `$name` | ${cells.join(' | ')} |');
  }
  b.writeln('| _suite p50_ | ${recent.map((e) => secs((e['phases'] as Map)['runP50Ms'])).join(' | ')} |');
  b.writeln();
  b.writeln('✅ stable · ⚠️ scattered · ❌ consistent-step · ❔ single failure · 🛠 infra · Q quarantined');
  b.writeln();

  b.writeln('## All audits');
  b.writeln();
  b.writeln('| audit | runs | stable | unstable | quarantined | suite p50 |');
  b.writeln('|---|---|---|---|---|---|');
  for (final e in entries.reversed) {
    final tests = (e['tests'] as List).cast<Map<String, Object?>>();
    final stable = tests.where((t) => t['verdict'] == 'stable').length;
    final quar = tests.where((t) => t['quarantined'] == true).length;
    b.writeln('| ${e['auditId']} | ${e['runCount']} | $stable | ${tests.length - stable} | $quar | '
        '${secs((e['phases'] as Map)['runP50Ms'])} |');
  }
  return b.toString();
}

String _shortId(String auditId) {
  // audit_2026-08-27T1229 -> 08-27 12:29
  final m = RegExp(r'audit_\d{4}-(\d{2})-(\d{2})T(\d{2})(\d{2})').firstMatch(auditId);
  return m == null ? auditId : '${m[1]}-${m[2]} ${m[3]}:${m[4]}';
}

/// Imports audit reports under [artifactsRoot] (`audit_*/audit.json`) that
/// have no history entry yet — reports made before the history existed, or
/// on a machine whose entries were not committed. Returns the ids imported.
List<String> backfillHistory(Directory dir, Directory artifactsRoot) {
  if (!artifactsRoot.existsSync()) return const [];
  final known = loadHistory(dir).map((e) => e['auditId']).toSet();
  final imported = <String>[];
  final reports = artifactsRoot
      .listSync()
      .whereType<Directory>()
      .map((d) => File('${d.path}/audit.json'))
      .where((f) => f.existsSync())
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in reports) {
    final report = (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)
        .cast<String, Object?>();
    if (known.contains(report['auditId'])) continue;
    writeHistoryEntry(
      dir,
      historyEntryFromReport(report, meta: {'imported': true, 'host': Platform.localHostname}),
    );
    imported.add(report['auditId'] as String);
  }
  return imported;
}

/// Regenerates `<dir>/HISTORY.md` from the entries; returns the file.
File writeHistoryDocument(Directory dir) {
  dir.createSync(recursive: true);
  final f = File('${dir.path}/HISTORY.md');
  f.writeAsStringSync(renderHistory(loadHistory(dir)));
  return f;
}
