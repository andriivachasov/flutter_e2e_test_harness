import 'dart:io';

import 'package:e2e_orchestrator/src/config.dart';
import 'package:test/test.dart';

void main() {
  _optionalModes();
  test('loads defaults for a minimal config', () {
    final dir = Directory.systemTemp.createTempSync('e2e_cfg');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/e2e.yaml')..writeAsStringSync('run:\n');
    final config = HarnessConfig.load(f.path);
    expect(config.keepRuns, 20);
    expect(config.iosDeviceName, 'iPhone 16');
    expect(config.backendCommand, ['dart', 'run', 'bin/server.dart']);
    expect(config.prebuild, false);
    expect(config.rootDir, dir.absolute.path);
  });

  test('parses explicit values', () {
    final dir = Directory.systemTemp.createTempSync('e2e_cfg');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/e2e.yaml')..writeAsStringSync('''
run:
  keep_runs: 3
devices:
  ios:
    name: "iPhone 15"
  android:
    avd: my_avd
backend:
  command: ["dart", "run", "bin/x.dart"]
  start_timeout_seconds: 5
''');
    final config = HarnessConfig.load(f.path);
    expect(config.keepRuns, 3);
    expect(config.iosDeviceName, 'iPhone 15');
    expect(config.androidAvd, 'my_avd');
    expect(config.backendCommand, ['dart', 'run', 'bin/x.dart']);
    expect(config.backendStartTimeout, const Duration(seconds: 5));
  });

  test('findConfigFile walks upward', () {
    final dir = Directory.systemTemp.createTempSync('e2e_cfg');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/e2e.yaml').writeAsStringSync('run:\n');
    final nested = Directory('${dir.path}/a/b')..createSync(recursive: true);
    final found = HarnessConfig.findConfigFile(nested.path);
    expect(found, isNotNull);
    expect(found, endsWith('e2e.yaml'));
  });

  test('missing file throws ConfigError', () {
    expect(
      () => HarnessConfig.load('/nonexistent/e2e.yaml'),
      throwsA(isA<ConfigError>()),
    );
  });

  group('layered local config (secrets stay out of the repo)', () {
    Directory setup(String base, [String? local]) {
      final dir = Directory.systemTemp.createTempSync('e2e_layer');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/e2e.yaml').writeAsStringSync(base);
      if (local != null) {
        File('${dir.path}/e2e.local.yaml').writeAsStringSync(local);
      }
      return dir;
    }

    test('defaults are emulator-only and need no credentials', () {
      final dir = setup('run:\n');
      final c = HarnessConfig.load('${dir.path}/e2e.yaml', env: {});
      expect(c.firebase.mode, 'emulator');
      expect(c.firebase.isDemoProject, isTrue);
      expect(c.provisioner.emailDomain, 'e2e.example.com');
      expect(c.provisioner.usesDefaultPassword, isTrue);
      expect(c.firebase.effectiveApiKey, 'any');
      expect(c.firebase.validate(), isEmpty);
      expect(c.sources, hasLength(1));
    });

    test('e2e.local.yaml deep-merges over e2e.yaml', () {
      final dir = setup('''
firebase:
  mode: emulator
  project_id: demo-e2e-harness
  auth_emulator_port: 9099
devices:
  ios:
    name: "iPhone 16"
  android:
    avd: e2e_pixel
''', '''
firebase:
  mode: real
  project_id: real-test-project
  api_key: local-key
devices:
  android:
    avd: my_avd
''');
      final c = HarnessConfig.load('${dir.path}/e2e.yaml', env: {});
      expect(c.firebase.mode, 'real');
      expect(c.firebase.projectId, 'real-test-project');
      expect(c.firebase.apiKey, 'local-key');
      // Untouched keys survive the merge, at both nesting levels.
      expect(c.firebase.authEmulatorPort, 9099);
      expect(c.iosDeviceName, 'iPhone 16');
      expect(c.androidAvd, 'my_avd');
      expect(c.sources, hasLength(2));
    });

    test('environment overrides win over both files', () {
      final dir = setup(
        'firebase:\n  mode: emulator\n',
        'firebase:\n  mode: real\n  project_id: from-local\n',
      );
      final c = HarnessConfig.load('${dir.path}/e2e.yaml', env: {
        'E2E_FIREBASE_PROJECT_ID': 'from-env',
        'E2E_FIREBASE_AUTH_EMULATOR_PORT': '9999',
      });
      expect(c.firebase.projectId, 'from-env');
      expect(c.firebase.authEmulatorPort, 9999);
      expect(c.sources.last, contains('E2E_FIREBASE_PROJECT_ID'));
    });

    test('real mode without a Web API key is a fatal error (D23: the app '
        'signs users up/in with it; nothing else is needed)', () {
      final dir = setup('firebase:\n  mode: real\n  project_id: p\n');
      final c = HarnessConfig.load('${dir.path}/e2e.yaml', env: {});
      expect(c.firebase.validate().join(' '), contains('api_key'));
      final ok = HarnessConfig.load('${dir.path}/e2e.yaml',
          env: {'E2E_FIREBASE_API_KEY': 'AIzaFake'});
      expect(ok.firebase.validate(), isEmpty);
      expect(ok.firebase.effectiveApiKey, 'AIzaFake');
      expect(ok.firebase.toRedactedJson()['apiKey'], '<set>');
    });

    test('pool password comes from local config or env', () {
      final dir = setup('run:\n', 'provisioner:\n  pool_password: local-pw\n');
      final c = HarnessConfig.load('${dir.path}/e2e.yaml', env: {});
      expect(c.provisioner.poolPassword, 'local-pw');
      expect(c.provisioner.usesDefaultPassword, isFalse);
      final e = HarnessConfig.load('${dir.path}/e2e.yaml',
          env: {'E2E_POOL_PASSWORD': 'env-pw'});
      expect(e.provisioner.poolPassword, 'env-pw');
    });

    test('emulator mode refuses a non-demo emulator project id', () {
      final dir = setup('firebase:\n  emulator_project_id: real-project\n');
      final c = HarnessConfig.load('${dir.path}/e2e.yaml', env: {});
      expect(c.firebase.validate().join(' '), contains('demo-'));
    });

    test('a real project_id sitting in local config does not leak into '
        'emulator runs', () {
      final dir = setup('firebase:\n  mode: emulator\n',
          'firebase:\n  project_id: firebase-spike-real\n');
      final c = HarnessConfig.load('${dir.path}/e2e.yaml', env: {});
      // This is the day-to-day setup: real values present, emulator active.
      expect(c.firebase.validate(), isEmpty);
      expect(c.firebase.effectiveProjectId, 'demo-e2e-harness');
      expect(c.firebase.toRedactedJson().toString(),
          isNot(contains('firebase-spike-real')));
    });

    test('redacted view never leaks secrets', () {
      final dir = setup('run:\n', '''
firebase:
  mode: real
  project_id: super-secret-project
  api_key: AIzaTOPSECRET
  service_account_key_path: /tmp/key.json
''');
      final c = HarnessConfig.load('${dir.path}/e2e.yaml', env: {});
      final json = c.firebase.toRedactedJson().toString();
      expect(json, isNot(contains('AIzaTOPSECRET')));
      expect(json, isNot(contains('super-secret-project')));
      expect(json, isNot(contains('/tmp/key.json')));
      expect(json, contains('<set>'));
    });

    test('bad enum values fail loudly', () {
      final bad = setup('firebase:\n  mode: nope\n');
      expect(() => HarnessConfig.load('${bad.path}/e2e.yaml', env: {}),
          throwsA(isA<ConfigError>()));
    });
  });
}

void _optionalModes() {
  test('firebase.mode none and an empty backend command are valid', () {
    final dir = Directory.systemTemp.createTempSync('e2e_cfg');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/e2e.yaml')..writeAsStringSync('''
backend:
  command: []
firebase:
  mode: none
''');
    final config = HarnessConfig.load(f.path);
    expect(config.hasBackend, false);
    expect(config.firebase.isNone, true);
    expect(config.firebase.validate(), isEmpty);
    expect(config.firebase.toRedactedJson()['projectId'], isNull);
  });
}
