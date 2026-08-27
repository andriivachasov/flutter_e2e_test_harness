import 'dart:convert';
import 'dart:io';

/// Named seed profiles (R16): `<seeds.dir>/<name>.json`, each a JSON object
/// whose shape is the *backend's* contract. The harness never interprets
/// it — it reads the file and posts it to the backend's seed endpoint with
/// the target user attached. That keeps seeding declarative and app-agnostic
/// and rules out the two anti-patterns R16 forbids (driving the UI to create
/// data, or writing to the datastore behind the backend's back).
class SeedLoader {
  SeedLoader(this.dir);

  final Directory dir;

  File fileFor(String profile) => File('${dir.path}/$profile.json');

  /// Profile names available, sorted.
  List<String> profiles() {
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .map((n) => n.substring(0, n.length - 5))
        .toList()
      ..sort();
  }

  /// Loads and validates one profile.
  Map<String, Object?> load(String profile) {
    final file = fileFor(profile);
    if (!file.existsSync()) {
      throw StateError('seed profile "$profile" not found at ${file.path}');
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw StateError('seed profile "$profile" must be a JSON object');
    }
    return decoded.cast<String, Object?>();
  }

  /// Parses every profile; returns problems (empty = all good). For doctor.
  List<String> validateAll() {
    final problems = <String>[];
    for (final name in profiles()) {
      try {
        load(name);
      } on Object catch (e) {
        problems.add('$name: $e');
      }
    }
    return problems;
  }
}
