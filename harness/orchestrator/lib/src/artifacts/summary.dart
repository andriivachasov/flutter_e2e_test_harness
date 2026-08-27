import 'dart:convert';
import 'dart:io';

class RoleOutcome {
  RoleOutcome({
    required this.role,
    required this.platform,
    required this.deviceDescription,
    required this.passed,
    required this.timedOut,
    required this.aborted,
    required this.exitCode,
    required this.durationMs,
    required this.artifactDir,
    this.user,
    this.seedProfile,
    this.steps = const [],
    this.failedStep,
    this.failureMessage,
    this.appLaunchMs,
  });

  final String role;
  final String platform;
  final String deviceDescription;
  final bool passed;
  final bool timedOut;

  /// Killed by the orchestrator because the environment failed.
  final bool aborted;
  final int exitCode;
  final int durationMs;

  /// Relative to the run directory, e.g. `cross_user_chat/A`.
  final String artifactDir;

  /// The provisioned test user (uid/email — never the password).
  final Map<String, Object?>? user;

  /// Seed profile applied before the body ran (R8/R16), if any.
  final String? seedProfile;

  /// Steps the test reported (`sync.step`), in order, with durations (R15).
  final List<StepTiming> steps;

  /// Step that was running when the test failed (R14 clustering).
  final String? failedStep;
  final String? failureMessage;

  /// Build + install + launch phase: from role start until the app was
  /// first seen running on the device (R15). Null if never launched.
  final int? appLaunchMs;

  String get verdict => passed
      ? 'PASS'
      : aborted
          ? 'ABORTED'
          : timedOut
              ? 'TIMEOUT'
              : 'FAIL';

  Map<String, Object?> toJson() => {
        'role': role,
        'platform': platform,
        'device': deviceDescription,
        'passed': passed,
        'verdict': verdict,
        'timedOut': timedOut,
        'aborted': aborted,
        'exitCode': exitCode,
        'durationMs': durationMs,
        'user': user,
        'seedProfile': seedProfile,
        'appLaunchMs': appLaunchMs,
        'steps': steps.map((s) => s.toJson()).toList(),
        'failedStep': failedStep,
        'failureMessage': failureMessage,
        'artifacts': {
          'dir': artifactDir,
          'video': '$artifactDir/video.mp4',
          'appLog': '$artifactDir/app.log',
          'testLog': '$artifactDir/test.log',
          'screenshots': '$artifactDir/screenshots',
        },
      };
}

class StepTiming {
  StepTiming({required this.name, required this.startedAt, required this.durationMs});
  final String name;
  final DateTime startedAt;
  final int durationMs;
  Map<String, Object?> toJson() => {
        'name': name,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'durationMs': durationMs,
      };
}

class TestOutcome {
  TestOutcome({
    required this.name,
    required this.tags,
    required this.roles,
    required this.startedAt,
    required this.finishedAt,
    this.infraError,
    this.provisionMs = 0,
    this.quarantined = false,
  });

  final String name;
  final Set<String> tags;
  final List<RoleOutcome> roles;
  final DateTime startedAt;
  final DateTime finishedAt;

  /// Set when the test could not be executed to a verdict (device/backend
  /// failure, unavailable platform).
  final String? infraError;

  /// Time spent acquiring users and applying seeds before the body (R15).
  final int provisionMs;

  /// Carries the quarantine tag (R14): reported, but a failure does not
  /// fail the run.
  final bool quarantined;

  /// Whether this outcome counts against the run's exit code.
  bool get blocking => !passed && !quarantined;

  bool get passed => infraError == null && roles.every((r) => r.passed);

  String get verdict => passed
      ? 'PASS'
      : infraError != null
          ? 'INFRA'
          : roles.any((r) => r.aborted)
              ? 'ABORTED'
              : 'FAIL';

  Map<String, Object?> toJson() => {
        'name': name,
        'tags': tags.toList()..sort(),
        'passed': passed,
        'verdict': verdict,
        'quarantined': quarantined,
        'infraError': infraError,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'durationMs': finishedAt.difference(startedAt).inMilliseconds,
        'provisionMs': provisionMs,
        'backendLog': '$name/backend.log',
        'roles': roles.map((r) => r.toJson()).toList(),
      };
}

/// Per-run timing breakdown (R15 groundwork): where the wall time went.
class RunTimings {
  final Map<String, int> deviceBootMs = {};
  int backendStartMs = 0;
  int authEmulatorStartMs = 0;
  int provisionerPrepareMs = 0;

  Map<String, Object?> toJson() => {
        'backendStartMs': backendStartMs,
        'authEmulatorStartMs': authEmulatorStartMs,
        'provisionerPrepareMs': provisionerPrepareMs,
        'deviceBootMs': deviceBootMs,
      };
}

/// Writes summary.json (for agents, R12) and summary.html (for humans).
void writeSummary({
  required Directory runDir,
  required String runId,
  required DateTime startedAt,
  required List<TestOutcome> outcomes,
  required List<String> warnings,
  required RunTimings timings,
  required int exitCode,
  Map<String, Object?> environment = const {},
  int seq = 0,
}) {
  final finishedAt = DateTime.now();
  final passed = outcomes.isNotEmpty && outcomes.every((o) => !o.blocking);
  final json = {
    'runId': runId,
    'seq': seq,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'finishedAt': finishedAt.toUtc().toIso8601String(),
    'durationMs': finishedAt.difference(startedAt).inMilliseconds,
    'passed': passed,
    'exitCode': exitCode,
    'counts': {
      'total': outcomes.length,
      'passed': outcomes.where((o) => o.passed).length,
      'failed': outcomes.where((o) => !o.passed).length,
      'quarantinedFailed':
          outcomes.where((o) => !o.passed && o.quarantined).length,
    },
    'timings': timings.toJson(),
    'environment': environment,
    'warnings': warnings,
    'logs': {
      'backend': 'backend.log',
      'orchestrator': 'orchestrator.log',
      'firebase': 'firebase.log',
    },
    'tests': outcomes.map((o) => o.toJson()).toList(),
  };
  File('${runDir.path}/summary.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

  File('${runDir.path}/summary.html').writeAsStringSync(_html(
    runDir: runDir,
    runId: runId,
    startedAt: startedAt,
    finishedAt: finishedAt,
    outcomes: outcomes,
    warnings: warnings,
    timings: timings,
    exitCode: exitCode,
    environment: environment,
  ));
}

String _html({
  required Directory runDir,
  required String runId,
  required DateTime startedAt,
  required DateTime finishedAt,
  required List<TestOutcome> outcomes,
  required List<String> warnings,
  required RunTimings timings,
  required int exitCode,
  required Map<String, Object?> environment,
}) {
  final passed = outcomes.isNotEmpty && outcomes.every((o) => !o.blocking);
  final sections = StringBuffer();

  for (final o in outcomes) {
    final cls = o.passed ? 'pass' : (o.quarantined ? 'quar' : 'fail');
    sections.writeln('<section class="test">');
    sections.writeln('<h2><span class="badge $cls">'
        '${o.passed ? o.verdict : (o.quarantined ? 'QUARANTINED ${o.verdict}' : o.verdict)}</span> '
        '${_esc(o.name)} <small>${_esc((o.tags.toList()..sort()).join(', '))}'
        ' · ${_secs(o.finishedAt.difference(o.startedAt).inMilliseconds)}'
        ' · <a href="${_esc(o.name)}/backend.log">backend.log</a></small></h2>');
    if (o.infraError != null) {
      sections.writeln('<p class="infra">${_esc(o.infraError!)}</p>');
    }
    for (final r in o.roles) {
      final rcls = r.passed ? 'pass' : 'fail';
      final dir = r.artifactDir;
      sections.writeln('<div class="role">');
      final userText = r.user == null
          ? ''
          : ' · user ${_esc('${r.user!['email']}')}'
              '${r.seedProfile == null ? '' : ' (seed: ${_esc(r.seedProfile!)})'}';
      sections.writeln('<h3><span class="badge $rcls">${r.verdict}</span> '
          'role ${_esc(r.role)} — ${_esc(r.deviceDescription)}$userText '
          '<small>${_secs(r.durationMs)} · exit ${r.exitCode} · '
          '<a href="$dir/video.mp4">video</a> · '
          '<a href="$dir/app.log">app.log</a> · '
          '<a href="$dir/test.log">test.log</a></small></h3>');
      if (r.steps.isNotEmpty || r.appLaunchMs != null) {
        final parts = [
          if (r.appLaunchMs != null) 'build+install+launch ${_secs(r.appLaunchMs!)}',
          for (final s in r.steps) '${_esc(s.name)} ${_secs(s.durationMs)}',
        ];
        sections.writeln('<p class="steps">${parts.join(' → ')}</p>');
      }
      if (r.failedStep != null || r.failureMessage != null) {
        sections.writeln('<p class="infra">failed at step '
            '<b>${_esc(r.failedStep ?? '?')}</b>: '
            '${_esc(_oneLine(r.failureMessage ?? ''))}</p>');
      }
      final shots = _screenshots(runDir, dir);
      if (shots.isNotEmpty) {
        sections.writeln('<div class="shots">');
        for (final shot in shots) {
          final label = shot.replaceAll(RegExp(r'\.png$'), '');
          sections.writeln('<figure><a href="$dir/screenshots/$shot">'
              '<img loading="lazy" src="$dir/screenshots/$shot" alt="$label">'
              '</a><figcaption>${_esc(label)}</figcaption></figure>');
        }
        sections.writeln('</div>');
      }
      sections.writeln('</div>');
    }
    sections.writeln('</section>');
  }

  final warningsHtml = warnings.isEmpty
      ? ''
      : '<h2>Warnings</h2><ul class="warnings">'
          '${warnings.map((w) => '<li>${_esc(w)}</li>').join()}</ul>';
  final boot = timings.deviceBootMs.entries
      .map((e) => '${e.key} ${_secs(e.value)}')
      .join(', ');

  return '''
<!doctype html>
<html><head><meta charset="utf-8"><title>e2e run $runId</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; color: #222; }
  h1 { margin-bottom: .2rem; }
  .meta { color: #555; margin-bottom: 1.5rem; }
  .badge { display: inline-block; padding: .1rem .5rem; border-radius: .3rem; font-size: .8em; color: #fff; vertical-align: middle; }
  .badge.pass { background: #0a7d38; }
  .badge.fail { background: #c0182b; }
  .badge.quar { background: #b8860b; }
  .steps { color: #555; font-size: .85em; margin: .2rem 0 .4rem 1rem; }
  section.test { border: 1px solid #ddd; border-radius: .5rem; padding: 1rem 1.2rem; margin-bottom: 1.2rem; }
  section.test h2 { margin: 0 0 .5rem; font-size: 1.15em; }
  .role { margin: .6rem 0 .2rem 1rem; }
  .role h3 { margin: .4rem 0; font-size: 1em; font-weight: 500; }
  small { color: #666; font-weight: 400; }
  .infra { color: #c0182b; white-space: pre-wrap; }
  .shots { display: flex; flex-wrap: wrap; gap: .6rem; margin: .4rem 0 .6rem; }
  .shots figure { margin: 0; width: 120px; text-align: center; font-size: .75em; color: #555; }
  .shots img { width: 120px; border: 1px solid #ccc; border-radius: .3rem; }
  .warnings li { color: #8a5a00; }
</style></head><body>
<h1><span class="badge ${passed ? 'pass' : 'fail'}">${passed ? 'PASS' : 'FAIL'}</span> Run $runId</h1>
<p class="meta">${outcomes.where((o) => o.passed).length}/${outcomes.length} tests passed
· ${_secs(finishedAt.difference(startedAt).inMilliseconds)} total
· exit $exitCode
· started ${startedAt.toLocal()}
· backend start ${_secs(timings.backendStartMs)}${boot.isEmpty ? '' : ' · device boot: $boot'}
· firebase ${_esc('${(environment['firebase'] as Map?)?['mode'] ?? '?'}')} / provisioner ${_esc('${(environment['provisioner'] as Map?)?['mode'] ?? '?'}')}
· <a href="backend.log">backend.log</a>
· <a href="firebase.log">firebase.log</a>
· <a href="orchestrator.log">orchestrator.log</a>
· <a href="summary.json">summary.json</a></p>
$sections
$warningsHtml
</body></html>
''';
}

List<String> _screenshots(Directory runDir, String roleDir) {
  final dir = Directory('${runDir.path}/$roleDir/screenshots');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.png'))
      .toList()
    ..sort();
}

String _secs(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

/// Failure text without stack frames, whitespace collapsed, capped.
String _oneLine(String message) {
  var m = message;
  final frame = RegExp(r'\n\s*#\d+\s').firstMatch(m);
  if (frame != null) m = m.substring(0, frame.start);
  m = m.replaceAll(RegExp(r'\s+'), ' ').trim();
  return m.length > 300 ? '${m.substring(0, 300)}…' : m;
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
