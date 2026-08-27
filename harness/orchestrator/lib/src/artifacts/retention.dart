import 'dart:io';

/// Keep-last-N run retention (D9). Run directories sort chronologically by
/// name (they start with an ISO timestamp). Returns the paths removed.
List<String> pruneRuns(Directory artifactsRoot, {required int keep}) =>
    _prune(artifactsRoot, keep: keep, matches: RegExp(r'^\d{4}-\d{2}-\d{2}T'));

/// Keep-last-N for `audit_<timestamp>` report directories (D24). Reports
/// are self-contained (they snapshot their runs' summaries) and their
/// durable trace lives in the history directory, so pruning loses nothing
/// the history keeps.
List<String> pruneAudits(Directory artifactsRoot, {required int keep}) =>
    _prune(artifactsRoot, keep: keep, matches: RegExp(r'^audit_\d{4}-'));

List<String> _prune(
  Directory root, {
  required int keep,
  required RegExp matches,
}) {
  if (!root.existsSync()) return const [];
  final dirs = root
      .listSync()
      .whereType<Directory>()
      .where((d) => matches.hasMatch(
          d.uri.pathSegments.where((s) => s.isNotEmpty).last))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final removed = <String>[];
  while (dirs.length > keep) {
    final victim = dirs.removeAt(0);
    try {
      victim.deleteSync(recursive: true);
      removed.add(victim.path);
    } on Object {
      // best effort — a locked file must not fail the run
    }
  }
  return removed;
}
