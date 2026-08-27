import 'dart:io';

import 'package:yaml/yaml.dart';

import '../config.dart';
import '../devices/device.dart';

/// One participant in a test: which role it plays and on which platform.
/// A null [platform] means "any configured device" — the scheduler picks
/// whichever is free (inter-test sharding, R19a).
class RoleSpec {
  const RoleSpec(this.role, this.platform);
  final String role;
  final DevicePlatform? platform;

  String describe() => '$role:${platform?.name ?? 'any'}';
}

/// A runnable e2e test known to the orchestrator.
class TestSpec {
  const TestSpec({
    required this.name,
    required this.target,
    required this.roles,
    required this.tags,
    this.seeds = const {},
    this.userScopes = const {},
  });

  final String name;

  /// Path of the test file, relative to the app directory.
  final String target;
  final List<RoleSpec> roles;
  final Set<String> tags;

  /// R8 preconditions: role -> seed profile name applied to that role's
  /// user before the test body runs. Roles without an entry start empty.
  final Map<String, String> seeds;

  /// D23: role -> pool scope label (`users:` in the manifest). Roles
  /// without an entry use the test name, i.e. their own account.
  final Map<String, String> userScopes;

  /// The pool scope for [role].
  String scopeFor(String role) => userScopes[role] ?? name;

  bool get isMultiUser => roles.length > 1;

  /// Platforms this test can only run on (fixed roles).
  Set<DevicePlatform> get fixedPlatforms =>
      roles.map((r) => r.platform).nonNulls.toSet();
}

/// Loads `<app.dir>/<app.tests_manifest>` (default
/// `integration_test/e2e_tests.yaml`). See that file for the schema.
List<TestSpec> loadTests(HarnessConfig config) {
  final path = '${config.resolve(config.appDir)}/${config.testsManifest}';
  final file = File(path);
  if (!file.existsSync()) {
    throw ConfigError('test manifest not found: $path');
  }
  final root = loadYaml(file.readAsStringSync());
  final list = root is YamlMap ? root['tests'] : null;
  if (list is! YamlList) {
    throw ConfigError('$path: top-level "tests" must be a list');
  }

  final specs = <TestSpec>[];
  final seen = <String>{};
  for (final (i, node) in list.indexed) {
    if (node is! YamlMap) throw ConfigError('$path: tests[$i] must be a map');
    final name = node['name'];
    if (name is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
      throw ConfigError('$path: tests[$i].name must match [A-Za-z0-9_-]+');
    }
    if (!seen.add(name)) throw ConfigError('$path: duplicate test "$name"');

    final target = node['target'];
    if (target is! String) {
      throw ConfigError('$path: test "$name" needs a "target" file path');
    }
    if (!File('${config.resolve(config.appDir)}/$target').existsSync()) {
      throw ConfigError('$path: test "$name" target does not exist: $target');
    }

    final tagsNode = node['tags'];
    final tags = tagsNode is YamlList
        ? tagsNode.map((t) => t.toString()).toSet()
        : <String>{};
    if (tags.isEmpty) {
      throw ConfigError('$path: test "$name" needs at least one tag');
    }

    final rolesNode = node['roles'];
    if (rolesNode is! YamlMap || rolesNode.isEmpty) {
      throw ConfigError('$path: test "$name" needs a non-empty "roles" map');
    }
    final roles = <RoleSpec>[];
    for (final entry in rolesNode.entries) {
      final role = entry.key.toString();
      final platform = switch (entry.value.toString()) {
        'ios' => DevicePlatform.ios,
        'android' => DevicePlatform.android,
        'any' => null,
        final other => throw ConfigError(
            '$path: test "$name" role "$role": platform must be '
            'ios|android|any, got "$other"',
          ),
      };
      roles.add(RoleSpec(role, platform));
    }

    final seedsNode = node['seed'];
    final seeds = <String, String>{};
    if (seedsNode != null) {
      if (seedsNode is! YamlMap) {
        throw ConfigError('$path: test "$name" "seed" must be a map of '
            'role -> profile name');
      }
      for (final entry in seedsNode.entries) {
        final role = entry.key.toString();
        if (!roles.any((r) => r.role == role)) {
          throw ConfigError('$path: test "$name" seeds unknown role "$role"');
        }
        final profile = entry.value.toString();
        final file = File('${config.resolve(config.seedsDir)}/$profile.json');
        if (!file.existsSync()) {
          throw ConfigError('$path: test "$name" role "$role": seed profile '
              '"$profile" not found at ${file.path}');
        }
        seeds[role] = profile;
      }
    }

    final usersNode = node['users'];
    final userScopes = <String, String>{};
    if (usersNode != null) {
      if (usersNode is! YamlMap) {
        throw ConfigError('$path: test "$name" "users" must be a map of '
            'role -> pool scope label');
      }
      for (final entry in usersNode.entries) {
        final role = entry.key.toString();
        if (!roles.any((r) => r.role == role)) {
          throw ConfigError('$path: test "$name" users: unknown role "$role"');
        }
        final label = entry.value.toString();
        if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(label)) {
          throw ConfigError('$path: test "$name" users.$role must match '
              '[A-Za-z0-9_-]+');
        }
        userScopes[role] = label;
      }
    }

    specs.add(TestSpec(
      name: name,
      target: target,
      roles: roles,
      tags: tags,
      seeds: seeds,
      userScopes: userScopes,
    ));
  }
  return specs;
}

/// Applies `--test` / `--tag` selection.
List<TestSpec> selectTests(
  List<TestSpec> all, {
  String? testName,
  Set<String>? tags,
}) {
  return all.where((t) {
    if (testName != null && t.name != testName) return false;
    if (tags != null && tags.isNotEmpty && !t.tags.any(tags.contains)) {
      return false;
    }
    return true;
  }).toList();
}
