import 'dart:io';

import 'package:e2e_orchestrator/src/artifacts/retention.dart';
import 'package:e2e_orchestrator/src/audit/audit.dart';
import 'package:e2e_orchestrator/src/audit/history.dart';
import 'package:e2e_orchestrator/src/cli/devices.dart' as cmd;
import 'package:e2e_orchestrator/src/cli/doctor.dart' as cmd;
import 'package:e2e_orchestrator/src/config.dart';
import 'package:e2e_orchestrator/src/run/runner.dart';
import 'package:e2e_orchestrator/src/tests/registry.dart';

const _usage = '''
e2e — Flutter e2e test harness orchestrator

Usage:
  e2e doctor                     verify local environment (exit 1 on failure)
  e2e run [--test <name>] [--tag <tag>]... [--keep-all]
                                 run all tests, one test, or tests with any
                                 of the given tags; artifacts in runs/<id>/
  e2e audit --runs N [--test <name>] [--tag <tag>]... [--keep-all]
                                 run the selection N times; report pass
                                 rate, p50/p95, failure clusters, phase
                                 timings and a quarantine suggestion
  e2e list                       list tests from the app's test manifest
  e2e devices                    show configured devices and their state
  e2e prune                      delete runs/audits beyond run.keep_runs /
                                 run.keep_audits
  e2e history                    regenerate <history_dir>/HISTORY.md from
                                 the committed audit entries (imports any
                                 runs/audit_*/audit.json not yet recorded)

Options:
  --config <path>                path to e2e.yaml (default: search upward)
  --keep-all                     do not prune old runs after this run

Exit codes (run): 0 all passed · 1 test failures · 2 infra/config error
Exit codes (audit): 0 every non-quarantined test stable · 1 unstable tests
                    · 2 infra/config error
''';

Future<void> main(List<String> args) async {
  String? configPath;
  String? testName;
  final tags = <String>{};
  var keepAll = false;
  var runs = 5;
  String? command;

  String needValue(int i) {
    if (i + 1 >= args.length || args[i + 1].startsWith('-')) {
      stderr.writeln('${args[i]} needs a value\n$_usage');
      exit(2);
    }
    return args[i + 1];
  }

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--config':
        configPath = needValue(i++);
      case '--test':
        testName = needValue(i++);
      case '--tag':
        tags.add(needValue(i++));
      case '--keep-all':
        keepAll = true;
      case '--runs':
        runs = int.tryParse(needValue(i++)) ?? 0;
        if (runs < 1) {
          stderr.writeln('--runs needs a positive integer');
          exit(2);
        }
      case '--help' || '-h':
        stdout.write(_usage);
        exit(0);
      default:
        if (command == null && !args[i].startsWith('-')) {
          command = args[i];
        } else {
          stderr.writeln('unknown argument: ${args[i]}\n$_usage');
          exit(2);
        }
    }
  }

  if (command == null) {
    stdout.write(_usage);
    exit(2);
  }

  configPath ??= HarnessConfig.findConfigFile(Directory.current.path);
  if (configPath == null) {
    stderr.writeln('e2e.yaml not found in this directory or any parent; '
        'pass --config <path>');
    exit(2);
  }

  late final HarnessConfig config;
  try {
    config = HarnessConfig.load(configPath);
  } on ConfigError catch (e) {
    stderr.writeln('$e');
    exit(2);
  }

  switch (command) {
    case 'doctor':
      exit(await cmd.doctor(config));
    case 'run':
      exit(await Runner(config).run(
        testName: testName,
        tags: tags,
        keepAll: keepAll,
      ));
    case 'audit':
      exit(await audit(
        config,
        runs: runs,
        testName: testName,
        tags: tags,
        keepAll: keepAll,
      ));
    case 'list':
      try {
        final tests = selectTests(
          loadTests(config),
          testName: testName,
          tags: tags,
        );
        for (final t in tests) {
          stdout.writeln('${t.name.padRight(24)} '
              '[${(t.tags.toList()..sort()).join(', ')}]  '
              '${t.roles.map((r) => r.describe()).join(' + ')}  '
              '${t.target}');
        }
        if (tests.isEmpty) stderr.writeln('no tests match the selection');
        exit(tests.isEmpty ? 2 : 0);
      } on ConfigError catch (e) {
        stderr.writeln('$e');
        exit(2);
      }
    case 'devices':
      exit(await cmd.devices(config));
    case 'prune':
      final root = Directory(config.resolve(config.artifactsDir));
      final removed = [
        ...pruneRuns(root, keep: config.keepRuns),
        ...pruneAudits(root, keep: config.keepAudits),
      ];
      for (final r in removed) {
        stdout.writeln('removed $r');
      }
      stdout.writeln('kept the newest ${config.keepRuns} runs and '
          '${config.keepAudits} audits (${removed.length} removed)');
      exit(0);
    case 'history':
      final dir = Directory(config.resolve(config.historyDir));
      final imported = backfillHistory(
        dir,
        Directory(config.resolve(config.artifactsDir)),
      );
      for (final id in imported) {
        stdout.writeln('imported $id from ${config.artifactsDir}/');
      }
      final doc = writeHistoryDocument(dir);
      stdout.writeln('${loadHistory(dir).length} audit(s) → ${doc.path}');
      exit(0);
    default:
      stderr.writeln('unknown command: $command\n$_usage');
      exit(2);
  }
}
