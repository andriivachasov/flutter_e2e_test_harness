import 'dart:io';

import 'package:yaml/yaml.dart';

/// Typed view over e2e.yaml. All relative paths resolve against [rootDir],
/// the directory containing the config file.
class HarnessConfig {
  HarnessConfig({
    required this.rootDir,
    required this.artifactsDir,
    required this.keepRuns,
    required this.keepAudits,
    required this.historyDir,
    required this.captureVideo,
    required this.quarantineTag,
    required this.iosDeviceName,
    required this.androidAvd,
    required this.androidGpu,
    required this.backendDir,
    required this.backendCommand,
    required this.backendPortFlag,
    required this.backendHealthPath,
    required this.backendStartTimeout,
    required this.backendSeedPath,
    required this.backendResetUserPath,
    required this.backendResetPath,
    required this.backendTestHeaders,
    required this.seedsDir,
    required this.appDir,
    required this.testsManifest,
    required this.iosBundleId,
    required this.androidPackage,
    required this.prebuild,
    required this.resetAppData,
    required this.buildTimeout,
    required this.testTimeout,
    required this.appReadyTimeout,
    required this.stepTimeout,
    required this.firebase,
    required this.provisioner,
    required this.sources,
  });

  final String rootDir;
  final String artifactsDir;
  final int keepRuns;

  /// Keep-last-N for `runs/audit_*` report directories (D24).
  final int keepAudits;

  /// Where audit history entries and HISTORY.md live — committed, not
  /// under artifacts_dir (D24). Relative to the repo root.
  final String historyDir;

  /// Screen recording per role. Off makes runs faster and avoids the
  /// emulator's fragile graphics path; screenshots and logs are unaffected.
  final bool captureVideo;

  /// Tests carrying this tag run and are reported, but their failures do
  /// not fail the run (R14 flake quarantine).
  final String quarantineTag;
  final String iosDeviceName;
  final String androidAvd;

  /// `emulator -gpu <mode>` for emulators the harness boots. Empty = let the
  /// emulator choose (which may be software Vulkan; see e2e.yaml).
  final String androidGpu;
  final String backendDir;
  final List<String> backendCommand;

  /// Template for the argument(s) that tell the backend which port to
  /// listen on, appended to [backendCommand]. Every `{port}` occurrence is
  /// replaced with the run's port. Default `["--port", "{port}"]`; write
  /// `"--server.port={port}"` for Spring Boot, `["-p", "{port}"]` for
  /// Rails, `"127.0.0.1:{port}"` for a Django-style positional argument.
  final List<String> backendPortFlag;

  /// [backendPortFlag] with `{port}` substituted — what the backend
  /// command is actually launched with.
  List<String> backendPortArgs(int port) =>
      [for (final part in backendPortFlag) part.replaceAll('{port}', '$port')];

  final String backendHealthPath;
  final Duration backendStartTimeout;

  /// False when `backend.command` is empty: the harness starts no backend,
  /// passes no E2E_BACKEND_URL, and seeding / account resets are
  /// unavailable (the app talks to whatever it is configured for).
  bool get hasBackend => backendCommand.isNotEmpty;

  /// Test-only backend endpoints the harness drives (R9b, R16). Enabled in
  /// the backend by E2E_TEST_MODE=1; paths overridable per app.
  final String backendSeedPath;
  final String backendResetUserPath;
  final String backendResetPath;

  /// Optional shared secret sent with every `/test/*` request (issue #7).
  /// Empty by default, so a setup that does not configure one sends exactly
  /// the headers it always did. The values are secrets: only
  /// [BackendTestHeaders.toRedactedJson] may reach a log or an artifact.
  final BackendTestHeaders backendTestHeaders;

  /// Directory of named seed profiles (`<name>.json`), relative to root.
  final String seedsDir;
  final String appDir;

  /// Test manifest path relative to [appDir].
  final String testsManifest;
  final String iosBundleId;
  final String androidPackage;
  final bool prebuild;

  /// R9a: wipe the app's on-device data before every test role, so every
  /// test starts from a cold app (no restored session).
  final bool resetAppData;
  final Duration buildTimeout;
  final Duration testTimeout;
  final Duration appReadyTimeout;
  final Duration stepTimeout;
  final FirebaseConfig firebase;
  final ProvisionerConfig provisioner;

  /// Config files/overrides that produced this config, in precedence order
  /// (later wins). Shown by `e2e doctor`; never contains secret values.
  final List<String> sources;

  String resolve(String relative) =>
      relative.startsWith('/') ? relative : '$rootDir/$relative';

  /// Walks up from [startDir] looking for e2e.yaml.
  static String? findConfigFile(String startDir) {
    var dir = Directory(startDir).absolute;
    while (true) {
      final candidate = File('${dir.path}/e2e.yaml');
      if (candidate.existsSync()) return candidate.path;
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// Name of the gitignored overlay that carries machine-local values and
  /// secrets (real Firebase project, service-account key path, ...).
  static const localConfigName = 'e2e.local.yaml';

  /// Loads `e2e.yaml`, then overlays `e2e.local.yaml` from the same directory
  /// if present, then environment overrides. Precedence, lowest first:
  ///
  ///   e2e.yaml  <  e2e.local.yaml  <  E2E_* environment variables
  ///
  /// The local overlay is deep-merged (a key set there replaces just that
  /// key), never committed, and is how real Firebase credentials reach the
  /// harness without entering the repository.
  static HarnessConfig load(String configPath, {Map<String, String>? env}) {
    final file = File(configPath);
    if (!file.existsSync()) {
      throw ConfigError('config file not found: $configPath');
    }
    final parsed = loadYaml(file.readAsStringSync());
    if (parsed is! YamlMap) {
      throw ConfigError('config is not a YAML map: $configPath');
    }

    final rootDir = file.absolute.parent.path;
    final sources = <String>[file.absolute.path];

    var merged = _toMap(parsed);
    final localFile = File('$rootDir/$localConfigName');
    if (localFile.existsSync()) {
      final localParsed = loadYaml(localFile.readAsStringSync());
      if (localParsed is! YamlMap && localParsed != null) {
        throw ConfigError('$localConfigName is not a YAML map');
      }
      if (localParsed is YamlMap) {
        merged = _deepMerge(merged, _toMap(localParsed));
      }
      sources.add(localFile.path);
    }

    final environment = env ?? Platform.environment;
    final applied = _applyEnvOverrides(merged, environment);
    if (applied.isNotEmpty) sources.add('env(${applied.join(', ')})');

    final root = merged;
    Map<String, Object?> section(String name) =>
        (root[name] as Map<String, Object?>?) ?? const {};

    final run = section('run');
    final devices = section('devices');
    final ios = (devices['ios'] as Map<String, Object?>?) ?? const {};
    final android = (devices['android'] as Map<String, Object?>?) ?? const {};
    final backend = section('backend');
    final app = section('app');
    final executor = section('executor');
    final sync = section('sync');
    final firebase = section('firebase');
    final provisioner = section('provisioner');
    final seeds = section('seeds');

    List<String> stringList(Object? node, String name) {
      if (node is! List) throw ConfigError('"$name" must be a list');
      return node.map((e) => e.toString()).toList();
    }

    // `backend.port_flag`: a string or a list of strings, at least one of
    // which carries the `{port}` placeholder. Default is `--port <n>`.
    List<String> portFlag(Object? node) {
      const defaultFlag = ['--port', '{port}'];
      if (node == null) return defaultFlag;
      final List<String> parts;
      if (node is String) {
        parts = [node];
      } else if (node is List) {
        parts = node.map((e) => e.toString()).toList();
      } else {
        throw ConfigError(
          '"backend.port_flag" must be a string or a list of strings',
        );
      }
      if (!parts.any((p) => p.contains('{port}'))) {
        throw ConfigError(
          '"backend.port_flag" must contain the {port} placeholder '
          '(got $parts) — otherwise the backend would start on '
          'the wrong port. Examples: ["--port", "{port}"] (default), '
          '"--server.port={port}", "127.0.0.1:{port}"',
        );
      }
      return parts;
    }

    Duration seconds(Map<String, Object?> map, String key, int fallback) =>
        Duration(seconds: (map[key] as num?)?.toInt() ?? fallback);

    return HarnessConfig(
      rootDir: rootDir,
      artifactsDir: (run['artifacts_dir'] as String?) ?? 'runs',
      keepRuns: (run['keep_runs'] as num?)?.toInt() ?? 20,
      keepAudits: (run['keep_audits'] as num?)?.toInt() ?? 10,
      historyDir: (run['history_dir'] as String?) ?? 'e2e-history',
      captureVideo: (run['capture_video'] as bool?) ?? true,
      quarantineTag: (run['quarantine_tag'] as String?) ?? 'quarantine',
      iosDeviceName: (ios['name'] as String?) ?? 'iPhone 16',
      androidAvd: (android['avd'] as String?) ?? 'e2e_pixel',
      androidGpu: (android['gpu'] as String?) ?? 'host',
      backendDir: (backend['dir'] as String?) ?? 'example/backend',
      // `command: []` = no backend (the harness starts none).
      backendCommand: backend['command'] == null
          ? ['dart', 'run', 'bin/server.dart']
          : stringList(backend['command'], 'backend.command'),
      backendPortFlag: portFlag(backend['port_flag']),
      backendHealthPath: (backend['health_path'] as String?) ?? '/health',
      backendStartTimeout: seconds(backend, 'start_timeout_seconds', 60),
      backendSeedPath: (backend['seed_path'] as String?) ?? '/test/seed',
      backendResetUserPath:
          (backend['reset_user_path'] as String?) ?? '/test/reset/user',
      backendResetPath: (backend['reset_path'] as String?) ?? '/test/reset',
      backendTestHeaders: BackendTestHeaders.from(backend['test_header']),
      seedsDir: (seeds['dir'] as String?) ?? 'example/seeds',
      appDir: (app['dir'] as String?) ?? 'example/app',
      testsManifest:
          (app['tests_manifest'] as String?) ?? 'integration_test/e2e_tests.yaml',
      iosBundleId: (app['ios_bundle_id'] as String?) ?? 'com.example.e2eExampleApp',
      androidPackage:
          (app['android_package'] as String?) ?? 'com.example.e2e_example_app',
      prebuild: (executor['prebuild'] as bool?) ?? false,
      resetAppData: (executor['reset_app_data'] as bool?) ?? true,
      buildTimeout: seconds(executor, 'build_timeout_seconds', 1200),
      testTimeout: seconds(executor, 'test_timeout_seconds', 900),
      appReadyTimeout: seconds(sync, 'app_ready_timeout_seconds', 600),
      stepTimeout: seconds(sync, 'step_timeout_seconds', 120),
      firebase: FirebaseConfig.from(firebase, rootDir: rootDir),
      provisioner: ProvisionerConfig.from(provisioner),
      sources: sources,
    );
  }
}

/// Deep-converts YAML nodes to plain Dart maps/lists so overlays can merge.
Map<String, Object?> _toMap(YamlMap node) {
  Object? convert(Object? v) => switch (v) {
        YamlMap() => _toMap(v),
        YamlList() => v.map(convert).toList(),
        _ => v,
      };
  return {
    for (final entry in node.entries)
      entry.key.toString(): convert(entry.value),
  };
}

/// Recursive merge: maps merge key-by-key, everything else is replaced.
Map<String, Object?> _deepMerge(
  Map<String, Object?> base,
  Map<String, Object?> overlay,
) {
  final out = Map<String, Object?>.of(base);
  for (final entry in overlay.entries) {
    final existing = out[entry.key];
    final incoming = entry.value;
    out[entry.key] = existing is Map<String, Object?> &&
            incoming is Map<String, Object?>
        ? _deepMerge(existing, incoming)
        : incoming;
  }
  return out;
}

/// Environment overrides for the values a CI job or a shell session needs to
/// set without editing files. Returns the names actually applied.
///
/// Kept to an explicit allowlist: config keys are not blindly reachable from
/// the environment, and every secret-bearing key can be supplied this way so
/// nothing has to be written to disk at all.
List<String> _applyEnvOverrides(
  Map<String, Object?> root,
  Map<String, String> env,
) {
  const overrides = <String, List<String>>{
    'E2E_FIREBASE_MODE': ['firebase', 'mode'],
    'E2E_FIREBASE_PROJECT_ID': ['firebase', 'project_id'],
    'E2E_FIREBASE_API_KEY': ['firebase', 'api_key'],
    'E2E_FIREBASE_AUTH_EMULATOR_PORT': ['firebase', 'auth_emulator_port'],
    'E2E_POOL_PASSWORD': ['provisioner', 'pool_password'],
    'E2E_POOL_EMAIL_DOMAIN': ['provisioner', 'email_domain'],
    // Optional shared secret for /test/* (issue #7); the value is a secret.
    'E2E_BACKEND_TEST_HEADER': ['backend', 'test_header', 'name'],
    'E2E_BACKEND_TEST_HEADER_VALUE': ['backend', 'test_header', 'value'],
    'E2E_ANDROID_AVD': ['devices', 'android', 'avd'],
    'E2E_ANDROID_GPU': ['devices', 'android', 'gpu'],
    'E2E_IOS_DEVICE': ['devices', 'ios', 'name'],
  };
  final applied = <String>[];
  for (final entry in overrides.entries) {
    final raw = env[entry.key];
    if (raw == null || raw.isEmpty) continue;
    var node = root;
    final path = entry.value;
    for (final key in path.take(path.length - 1)) {
      final next = node[key];
      if (next is Map<String, Object?>) {
        node = next;
      } else {
        final created = <String, Object?>{};
        node[key] = created;
        node = created;
      }
    }
    final leaf = path.last;
    node[leaf] = int.tryParse(raw) ?? raw;
    applied.add(entry.key);
  }
  return applied;
}

/// Firebase wiring (D2/D6/D23). Three modes:
///
///  * `emulator` (default) — the Auth emulator with a `demo-` project id.
///    Needs nothing but the firebase CLI.
///  * `real` — a dedicated test-only Firebase project (D6): its project id
///    and Web API key. Both are public client identifiers, not secrets,
///    but project-specific, so they live in the gitignored `e2e.local.yaml`
///    (or `E2E_FIREBASE_*`). The harness needs NO admin credentials (D23).
///  * `none` — the app has no Firebase Auth.
class FirebaseConfig {
  FirebaseConfig({
    required this.mode,
    required this.emulatorProjectId,
    required this.projectId,
    required this.apiKey,
    required this.authEmulatorPort,
    required this.cli,
  });

  factory FirebaseConfig.from(
    Map<String, Object?> node, {
    required String rootDir,
  }) {
    final mode = (node['mode'] as String?) ?? 'emulator';
    if (mode != 'emulator' && mode != 'real' && mode != 'none') {
      throw ConfigError('firebase.mode must be "emulator", "real" or "none", '
          'got "$mode"');
    }
    return FirebaseConfig(
      mode: mode,
      emulatorProjectId:
          (node['emulator_project_id'] as String?) ?? 'demo-e2e-harness',
      projectId: (node['project_id'] as String?) ?? '',
      apiKey: (node['api_key'] as String?) ?? '',
      authEmulatorPort: (node['auth_emulator_port'] as num?)?.toInt() ?? 0,
      cli: (node['cli'] as String?) ?? 'firebase',
    );
  }

  final String mode;

  /// Project id used in emulator mode. Must start with `demo-`.
  final String emulatorProjectId;

  /// Real (D6) project id. Only meaningful in `real` mode; it identifies a
  /// live project, so it belongs in the gitignored local config.
  final String projectId;

  /// Web API key: what the APP signs users in (and up) with. Any value
  /// works against the emulator; a real project needs its own.
  final String apiKey;

  /// Port for the Auth emulator the harness starts; 0 = pick a free one per
  /// run (collision-free under parallel runs, R19).
  final int authEmulatorPort;

  /// The Firebase CLI executable (`brew install firebase-cli`).
  final String cli;

  bool get isEmulator => mode == 'emulator';

  /// `none`: the target app has no Firebase Auth — no emulator is started
  /// and no users are provisioned (TestContext.user stays empty).
  bool get isNone => mode == 'none';

  /// The project id actually in force for this run.
  String get effectiveProjectId => isEmulator ? emulatorProjectId : projectId;

  /// Emulator project ids must start with `demo-`: the Firebase tooling then
  /// refuses to talk to a real project even if credentials are present.
  bool get isDemoProject => effectiveProjectId.startsWith('demo-');

  /// The API key the app is given: the real one, or `any` for the emulator.
  String get effectiveApiKey => isEmulator || apiKey.isEmpty ? 'any' : apiKey;

  /// Fatal problems: the app could not sign in with this configuration.
  List<String> validate() {
    final problems = <String>[];
    if (isNone) return problems;
    if (isEmulator) {
      if (!isDemoProject) {
        problems.add('firebase.mode is "emulator" but emulator_project_id '
            '"$emulatorProjectId" does not start with "demo-" — an emulator '
            'run must not be able to reach a real project');
      }
    } else {
      if (projectId.isEmpty) {
        problems.add('firebase.mode is "real" but project_id is unset — set '
            'it in ${HarnessConfig.localConfigName} or '
            'E2E_FIREBASE_PROJECT_ID');
      } else if (projectId.startsWith('demo-')) {
        problems.add('firebase.mode is "real" but project_id "$projectId" '
            'looks like an emulator project (demo- prefix)');
      }
      if (apiKey.isEmpty) {
        problems.add('firebase.mode is "real" but api_key is unset — the app '
            'signs users up/in with the project\'s Web API key (Firebase '
            'console > Project settings > General > Web API Key; set it in '
            '${HarnessConfig.localConfigName} or E2E_FIREBASE_API_KEY)');
      }
    }
    return problems;
  }

  /// Safe for logs, summaries and artifacts: secrets become presence flags.
  Map<String, Object?> toRedactedJson() => {
        'mode': mode,
        'projectId': isNone
            ? null
            : isEmulator
                ? emulatorProjectId
                : _redactId(effectiveProjectId),
        'apiKey': apiKey.isEmpty ? null : '<set>',
        'authEmulatorPort': authEmulatorPort,
      };

  /// Real project ids identify a live project; keep a short prefix for
  /// debuggability and drop the rest.
  static String _redactId(String id) =>
      id.length <= 4 ? '<set>' : '${id.substring(0, 4)}…<redacted>';
}

/// The fixed user pool (R10, D23): `<scope>-<role>@<email_domain>` with
/// one shared password. The app registers accounts on first use.
class ProvisionerConfig {
  ProvisionerConfig({required this.emailDomain, required this.poolPassword});

  /// Default pool password. Fine for the emulator; a real project should
  /// set its own in e2e.local.yaml (doctor warns otherwise).
  static const defaultPassword = 'e2e-Pool-Passw0rd';

  factory ProvisionerConfig.from(Map<String, Object?> node) =>
      ProvisionerConfig(
        emailDomain: (node['email_domain'] as String?) ?? 'e2e.example.com',
        poolPassword:
            '${node['pool_password'] ?? defaultPassword}',
      );

  /// Domain for pool emails (never a real mailbox).
  final String emailDomain;
  final String poolPassword;

  bool get usesDefaultPassword => poolPassword == defaultPassword;
}

/// Optional shared secret for the `/test/*` surface (issue #7).
///
/// That surface deletes arbitrary user data and must work *before* the
/// account exists, so it cannot be authenticated the normal way; the
/// recommended lock is to bind the test backend to loopback (playbook 03
/// §3.2). Integrators who want a second factor on top — or who cannot bind
/// to loopback — configure a header the orchestrator sends with every
/// `/test/*` request, and reject requests without it in the backend:
///
///     backend:
///       test_header:                 # one header, name/value
///         name: X-E2E-Test-Secret
///         value: "shared-secret"
///
///     backend:
///       test_header:                 # or several, as name: value
///         X-E2E-Test-Secret: "shared-secret"
///         X-Env: staging
///
/// Unset by default: with no `test_header` the orchestrator sends exactly
/// the headers it always sent. Values are secrets — they belong in the
/// gitignored `e2e.local.yaml` (or `E2E_BACKEND_TEST_HEADER` /
/// `E2E_BACKEND_TEST_HEADER_VALUE`) — and only [toRedactedJson] may enter a
/// log, a summary or any other artifact.
class BackendTestHeaders {
  const BackendTestHeaders(this.headers);

  const BackendTestHeaders.none() : headers = const {};

  /// Parses the `backend.test_header` node. Accepts a `{name:, value:}` pair
  /// or a map of header names to values; `null` means unset.
  factory BackendTestHeaders.from(Object? node) {
    if (node == null) return const BackendTestHeaders.none();
    if (node is! Map) {
      throw ConfigError('"backend.test_header" must be a map — either '
          '{name: <header>, value: <secret>} or {<header>: <secret>, ...}');
    }
    final map = node.map((k, v) => MapEntry('$k', v));
    if (map.containsKey('name') || map.containsKey('value')) {
      final name = '${map['name'] ?? ''}'.trim();
      final value = '${map['value'] ?? ''}';
      if (name.isEmpty || value.isEmpty) {
        throw ConfigError('"backend.test_header" needs both "name" and '
            '"value" (or drop the key entirely to send no extra header)');
      }
      return BackendTestHeaders({name: value});
    }
    final headers = <String, String>{};
    for (final entry in map.entries) {
      final name = entry.key.trim();
      final value = '${entry.value ?? ''}';
      if (name.isEmpty || value.isEmpty) {
        throw ConfigError('"backend.test_header" entry "${entry.key}" has an '
            'empty name or value');
      }
      headers[name] = value;
    }
    return BackendTestHeaders(headers);
  }

  /// Header name -> secret value. Never log or serialize this map.
  final Map<String, String> headers;

  bool get isEmpty => headers.isEmpty;
  bool get isNotEmpty => headers.isNotEmpty;

  /// Every configured value, for the redaction pass that scrubs subprocess
  /// output (the executor already does this for `E2E_USER_PASSWORD` and
  /// `E2E_FIREBASE_API_KEY`).
  Iterable<String> get secretValues =>
      headers.values.where((v) => v.isNotEmpty);

  /// Safe for logs, summaries and artifacts: names are kept (they are not
  /// secret and make a misconfiguration diagnosable), values become
  /// presence flags.
  Map<String, Object?> toRedactedJson() => {
        for (final name in headers.keys) name: '<set>',
      };

  @override
  String toString() => 'BackendTestHeaders(${toRedactedJson()})';
}

class ConfigError implements Exception {
  ConfigError(this.message);
  final String message;
  @override
  String toString() => 'ConfigError: $message';
}
