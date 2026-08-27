import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../seed/seed_loader.dart';
import '../tests/registry.dart';
import '../users/auth_probe.dart';
import '../util/gitignore.dart';
import '../util/android_sdk.dart';
import '../util/proc.dart';

/// Environment verification with actionable errors (R3).
/// Exit code 0 when all required checks pass.
Future<int> doctor(HarnessConfig config) async {
  var failures = 0;

  Future<void> check(
    String label, {
    required Future<String?> Function() probe, // null = ok, string = problem
    required String fix,
    bool required = true,
  }) async {
    String status;
    String? problem;
    try {
      problem = await probe();
    } on Object catch (e) {
      problem = '$e';
    }
    if (problem == null) {
      status = 'ok  ';
    } else if (required) {
      status = 'FAIL';
      failures++;
    } else {
      status = 'warn';
    }
    stdout.writeln('[$status] $label${problem == null ? '' : ' — $problem'}');
    if (problem != null) stdout.writeln('       fix: $fix');
  }

  Future<String?> haveCommand(List<String> cmd) async {
    final r = await runProc(cmd, timeout: const Duration(seconds: 30));
    return r.ok ? null : 'not runnable (${r.describe()})';
  }

  await check(
    'dart',
    probe: () => haveCommand(['dart', '--version']),
    fix: 'install Flutter (bundles Dart): https://docs.flutter.dev/get-started',
  );
  await check(
    'flutter',
    probe: () => haveCommand(['flutter', '--version']),
    fix: 'install Flutter: https://docs.flutter.dev/get-started',
  );
  await check(
    'patrol_cli',
    probe: () => haveCommand(['patrol', '--version']),
    fix: 'dart pub global activate patrol_cli '
        '(and add ~/.pub-cache/bin to PATH)',
  );
  if (!config.firebase.isNone) await check(
    'firebase CLI (Auth emulator)',
    required: config.firebase.isEmulator,
    probe: () => haveCommand([config.firebase.cli, '--version']),
    fix: 'bash m1/step4_firebase.sh (brew install firebase-cli); or set '
        'firebase.cli in e2e.yaml to the executable. Only the Auth '
        'emulator is used, so no Java runtime is needed',
  );

  if (Platform.isMacOS) {
    // Simulators need the full Xcode app: Command Line Tools alone ship an
    // xcrun that cannot run simctl. Say exactly that.
    const xcodeFix = 'install Xcode from the App Store, then: '
        'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer '
        '&& sudo xcodebuild -runFirstLaunch '
        '&& xcodebuild -downloadPlatform iOS';
    var haveXcode = false;
    await check(
      'xcrun simctl (Xcode)',
      probe: () async {
        final problem = await haveCommand(['xcrun', 'simctl', 'help']);
        haveXcode = problem == null;
        return problem;
      },
      fix: xcodeFix,
    );
    if (!haveXcode) {
      stdout.writeln('[skip] iOS simulator "${config.iosDeviceName}" — '
          'needs Xcode (above)');
    }
    await check(
      'cocoapods',
      probe: () => haveCommand(['pod', '--version']),
      fix: 'brew install cocoapods (Patrol\'s iOS setup is CocoaPods-based)',
    );
    if (haveXcode) await check(
      'iOS simulator "${config.iosDeviceName}"',
      probe: () async {
        final r = await runProc(
          ['xcrun', 'simctl', 'list', 'devices', 'available'],
          timeout: const Duration(seconds: 30),
        );
        if (!r.ok) return 'simctl failed';
        return r.stdout.contains(config.iosDeviceName)
            ? null
            : 'not in `simctl list devices available`';
      },
      fix: 'bash m1/step3_devices.sh creates it; or set devices.ios.name in '
          'e2e.yaml to a device from `xcrun simctl list devices available`',
    );
    // Disabling SwiftPM (Patrol's iOS setup is CocoaPods-based) stops Flutter
    // generating ios/Flutter/ephemeral/Packages/.packages/patrol-<version>/.
    // A leftover local Swift package reference then makes xcodebuild fail to
    // resolve dependencies before it builds anything.
    await check(
      'no stale patrol Swift package in Runner.xcodeproj',
      required: false,
      probe: () async {
        final dir = config.resolve(config.appDir);
        final pbxproj = File('$dir/ios/Runner.xcodeproj/project.pbxproj');
        if (!pbxproj.existsSync()) return null;
        final home = Platform.environment['HOME'];
        final settingsFiles = [
          File('$dir/pubspec.yaml'),
          if (home != null) File('$home/.flutter_settings'),
          if (home != null) File('$home/.config/flutter/settings'),
        ];
        final spmOff = settingsFiles.any((f) =>
            f.existsSync() &&
            RegExp(r'"?enable-swift-package-manager"?\s*:\s*false')
                .hasMatch(f.readAsStringSync()));
        if (!spmOff) return null;
        final referenced = RegExp(
          r'relativePath\s*=\s*"?[^";\n]*patrol-|productName\s*=\s*"?patrol"?\s*;',
        ).hasMatch(pbxproj.readAsStringSync());
        return referenced
            ? 'Swift Package Manager is disabled but ios/Runner.xcodeproj '
                'still references a patrol Swift package — xcodebuild will '
                'fail with "Could not resolve package dependencies"'
            : null;
      },
      fix: 'bash harness/tools/patrol_bootstrap.sh ${config.appDir} removes it '
          '(step "ios: stale SwiftPM patrol package"), or run it alone: '
          'cd ${config.appDir}/ios && ruby '
          '<harness>/tools/ios_spm_cleanup.rb',
    );
  } else {
    stdout.writeln('[warn] not macOS — iOS checks skipped, iOS tests will not run');
  }

  await check(
    'adb',
    probe: () => haveCommand(['adb', 'version']),
    fix: 'install Android SDK platform-tools and add to PATH',
  );
  await check(
    'Android AVD "${config.androidAvd}"',
    probe: () async {
      final r = await runProc(
        [emulatorBinary(), '-list-avds'],
        timeout: const Duration(seconds: 30),
      );
      if (!r.ok) {
        return '`emulator` not runnable — install the SDK emulator package '
            'or set \$ANDROID_HOME';
      }
      return r.stdout.split('\n').map((l) => l.trim()).contains(config.androidAvd)
          ? null
          : 'not in `emulator -list-avds`';
    },
    fix: 'bash m1/step3_devices.sh creates it (needs '
        'system-images;android-35;google_apis;arm64-v8a via sdkmanager); '
        'or set devices.android.avd in e2e.yaml to one of '
        '`emulator -list-avds`',
  );

  await check(
    'Android emulator GPU mode',
    required: false,
    probe: () async {
      final home = Platform.environment['HOME'];
      if (home == null) return null;
      final ini = File('$home/.android/avd/${config.androidAvd}.avd/config.ini');
      if (!ini.existsSync()) return null;
      final mode = ini
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('hw.gpu.mode'), orElse: () => '');
      if (mode.isEmpty || mode.endsWith('auto')) {
        return 'AVD "${config.androidAvd}" has ${mode.isEmpty ? 'no' : 'auto'} '
            'GPU mode — it may pick software Vulkan, which drops the adb '
            'connection during screenshots';
      }
      return null;
    },
    fix: 'set hw.gpu.mode=host in '
        '~/.android/avd/${config.androidAvd}.avd/config.ini '
        '(bash m1/step3_devices.sh does this); the harness also passes '
        '-gpu ${config.androidGpu} at boot',
  );

  // Leftovers from a crashed run collide with the next one (risk register).
  await check(
    'no leftover harness processes',
    required: false,
    probe: () async {
      final leftovers = <String>[];
      for (final (label, pattern) in [
        ('backend', r'bin/server\.dart --port'),
        ('iOS recorder', r'simctl io .* recordVideo'),
        ('patrol test', r'patrol test --target'),
        ('Auth emulator', r'emulators:start --only auth'),
        ('orchestrator run', r'e2e\.dart run'),
      ]) {
        final r = await runProc(['pgrep', '-fl', pattern],
            timeout: const Duration(seconds: 10));
        if (r.exitCode == 0 && r.stdout.trim().isNotEmpty) {
          final pids = r.stdout
              .trim()
              .split('\n')
              .map((l) => l.trim().split(' ').first)
              .join(', ');
          leftovers.add('$label (pid $pids)');
        }
      }
      return leftovers.isEmpty ? null : leftovers.join('; ');
    },
    fix: 'an `e2e run` may be active in another shell (devices are shared: '
        'wait for it); otherwise a previous run was interrupted — kill them '
        '(kill <pid>)',
  );

  final appDir = config.resolve(config.appDir);
  await check(
    'app platform folders',
    probe: () async {
      final missing = [
        if (!Directory('$appDir/android').existsSync()) 'android/',
        if (!Directory('$appDir/ios').existsSync()) 'ios/',
      ];
      return missing.isEmpty ? null : 'missing ${missing.join(' and ')} in $appDir';
    },
    fix: 'cd $appDir && flutter create --project-name e2e_example_app '
        '--org com.example .',
  );
  await check(
    'app dependencies resolved',
    probe: () async =>
        File('$appDir/.dart_tool/package_config.json').existsSync()
            ? null
            : 'pub deps not fetched',
    fix: 'cd $appDir && flutter pub get',
  );
  if (config.hasBackend) {
    await check(
      'backend directory',
      probe: () async => Directory(config.resolve(config.backendDir)).existsSync()
          ? null
          : '${config.resolve(config.backendDir)} does not exist',
      fix: 'set backend.dir/backend.command in e2e.yaml, or backend.command: [] '
          'if the harness must not start one',
    );
    if (config.backendCommand.first == 'dart') {
      await check(
        'backend dependencies resolved',
        probe: () async {
          final dir = config.resolve(config.backendDir);
          return File('$dir/.dart_tool/package_config.json').existsSync()
              ? null
              : 'pub deps not fetched';
        },
        fix: 'cd ${config.resolve(config.backendDir)} && dart pub get',
      );
    }
    if (config.backendTestHeaders.isNotEmpty) {
      // Names only — the values are secrets (issue #7).
      stdout.writeln('[info] /test/* shared secret: '
          '${config.backendTestHeaders.toRedactedJson()}');
    }
  } else {
    stdout.writeln('[info] backend.command is empty: the harness starts no '
        'backend (seeding and account resets unavailable)');
  }

  // --- Firebase / provisioning configuration (D2/D6, R10) ----------------
  stdout.writeln('[info] config sources: ${config.sources.join('  <  ')}');
  stdout.writeln('[info] firebase: mode=${config.firebase.mode} '
      'project=${config.firebase.toRedactedJson()['projectId']} '
      'pool: <scope>-<role>@${config.provisioner.emailDomain}');

  await check(
    'firebase configuration',
    probe: () async {
      final problems = config.firebase.validate();
      return problems.isEmpty ? null : problems.join('; ');
    },
    fix: 'cp ${HarnessConfig.localConfigName}.template '
        '${HarnessConfig.localConfigName} and fill in the firebase block '
        '(that file is gitignored), or export the E2E_FIREBASE_* variables',
  );

  // google-services.json / GoogleService-Info.plist are gitignored in most
  // Flutter repos, so a fresh clone or worktree lacks them — and nothing
  // notices until Gradle fails at :app:processDebugGoogleServices minutes
  // into a run, buried in runs/<id>/<test>/<role>/test.log.
  //
  // The gate is what the app's BUILD consumes, not firebase.mode: the
  // google-services plugin fails the build whenever it is applied, and an
  // app can use Firebase Analytics or Crashlytics while running the harness
  // with firebase.mode: none. (The example app talks to the Auth REST API
  // and applies no plugin, so no line is printed for it.)
  //
  // mentions() never throws: a file that cannot be read or is not valid
  // UTF-8 must not take doctor down with a stack trace before it has
  // reported anything.
  bool mentions(List<String> paths, String needle) => paths.any((p) {
        try {
          final f = File(p);
          if (!f.existsSync()) return false;
          return utf8
              .decode(f.readAsBytesSync(), allowMalformed: true)
              .contains(needle);
        } on IOException {
          return false;
        }
      });
  final androidUsesGoogleServices = mentions([
    '$appDir/android/app/build.gradle',
    '$appDir/android/app/build.gradle.kts',
    '$appDir/android/build.gradle',
    '$appDir/android/build.gradle.kts',
    '$appDir/android/settings.gradle',
    '$appDir/android/settings.gradle.kts',
  ], 'google-services');
  final iosUsesGoogleServices = Platform.isMacOS &&
      mentions(['$appDir/ios/Runner.xcodeproj/project.pbxproj'],
          'GoogleService-Info.plist');
  if (androidUsesGoogleServices || iosUsesGoogleServices) {
    await check(
      'Firebase app config files',
      probe: () async {
        final missing = [
          if (androidUsesGoogleServices &&
              !File('$appDir/android/app/google-services.json').existsSync())
            'android/app/google-services.json',
          if (iosUsesGoogleServices &&
              !File('$appDir/ios/Runner/GoogleService-Info.plist').existsSync())
            'ios/Runner/GoogleService-Info.plist',
        ];
        return missing.isEmpty
            ? null
            : 'missing ${missing.join(' and ')} in $appDir';
      },
      fix: 'cd $appDir && flutterfire configure (or copy the files from '
          'another checkout/worktree — they are gitignored in most Flutter '
          'repos, so a fresh clone has none). Without them the build dies '
          'minutes into a run at :app:processDebugGoogleServices',
    );
  }

  if (!config.firebase.isNone &&
      !config.firebase.isEmulator &&
      config.firebase.validate().isEmpty) {
    await check(
      'real project: Web API key + email/password sign-in (client probe)',
      probe: () => probeEmailPasswordSignIn(
        identityToolkitUrl: 'https://identitytoolkit.googleapis.com/v1',
        apiKey: config.firebase.apiKey,
      ),
      fix: 'firebase.api_key must be the project\'s Web API key (console > '
          'Project settings > General) and Email/Password must be enabled '
          '(console > Authentication > Sign-in method)',
    );
    await check(
      'pool password set for the real project',
      required: false,
      probe: () async => config.provisioner.usesDefaultPassword
          ? 'provisioner.pool_password is the built-in default; accounts in '
              'the real project will use it'
          : null,
      fix: 'set provisioner.pool_password in ${HarnessConfig.localConfigName} '
          '(or E2E_POOL_PASSWORD) — accounts are registered by the app with '
          'this password on first use',
    );
  }

  if (config.firebase.isEmulator && config.firebase.authEmulatorPort != 0) {
    await check(
      'Auth emulator port ${config.firebase.authEmulatorPort} free',
      required: false,
      probe: () async {
        try {
          final s = await ServerSocket.bind(
            InternetAddress.anyIPv4,
            config.firebase.authEmulatorPort,
          );
          await s.close();
          return null;
        } on SocketException {
          return 'port in use (another emulator or a previous run?)';
        }
      },
      fix: 'set firebase.auth_emulator_port: 0 to pick a free port per run, '
          'or stop whatever holds the port',
    );
  }

  await check(
    'seed profiles',
    required: false,
    probe: () async {
      final loader = SeedLoader(Directory(config.resolve(config.seedsDir)));
      if (!loader.dir.existsSync()) {
        return 'seeds.dir ${loader.dir.path} does not exist (fine unless a '
            'test declares a seed profile)';
      }
      final problems = loader.validateAll();
      return problems.isEmpty ? null : problems.join('; ');
    },
    fix: 'create ${config.resolve(config.seedsDir)}/<profile>.json (JSON '
        'objects in the backend\'s seed format); tests reference profiles '
        'by file name in the manifest\'s "seed" map',
  );

  // A secret that is not ignored is one `git add .` away from being public.
  await check(
    'secrets are gitignored',
    probe: () async {
      final candidates = <String>[HarnessConfig.localConfigName];
      final tracked = <String>[];
      for (final path in candidates) {
        final file = File(config.resolve(path));
        if (!file.existsSync()) continue;
        final r = await runProc(
          ['git', 'check-ignore', '-q', file.path],
          cwd: config.rootDir,
          timeout: const Duration(seconds: 10),
        );
        // 0 = ignored, 1 = NOT ignored, 128 = not a git repo (nothing to
        // leak yet, but the rule must already be in .gitignore).
        if (r.exitCode == 1) {
          tracked.add(path);
        } else if (r.exitCode >= 128) {
          // Not a git repo yet: git cannot answer, so evaluate the rules
          // ourselves. The rule must already exist, or `git init` followed
          // by `git add .` would commit the secret.
          final ignoreFile = File('${config.rootDir}/.gitignore');
          final rules = ignoreFile.existsSync()
              ? ignoreFile.readAsStringSync()
              : '';
          final relative = file.path.startsWith('${config.rootDir}/')
              ? file.path.substring(config.rootDir.length + 1)
              : file.path;
          if (!isIgnoredByRules(relative, rules)) {
            tracked.add('$path (no .gitignore rule; repo not initialized yet)');
          }
        }
      }
      return tracked.isEmpty ? null : 'NOT ignored: ${tracked.join(', ')}';
    },
    fix: 'add the listed paths to .gitignore before running `git init` / '
        '`git add`; secrets must never enter the repository history',
  );

  // D24: the audit memory must be committed, not swept away with runs/.
  await check(
    'audit history is NOT gitignored',
    required: false,
    probe: () async {
      final dir = config.resolve(config.historyDir);
      final probe = File('$dir/audit_probe.json');
      final r = await runProc(
        ['git', 'check-ignore', '-q', probe.path],
        cwd: config.rootDir,
        timeout: const Duration(seconds: 10),
      );
      if (r.exitCode == 0) return '${config.historyDir}/ is gitignored';
      if (r.exitCode >= 128) {
        final ignoreFile = File('${config.rootDir}/.gitignore');
        final rules = ignoreFile.existsSync() ? ignoreFile.readAsStringSync() : '';
        final relative = '${config.historyDir}/audit_probe.json';
        if (isIgnoredByRules(relative, rules)) {
          return '${config.historyDir}/ matches a .gitignore rule';
        }
      }
      return null;
    },
    fix: 'keep run.history_dir (${config.historyDir}) out of .gitignore: '
        'it holds one small JSON per audit plus HISTORY.md, the suite\'s '
        'memory across audits (D24)',
  );

  await check(
    'test manifest',
    probe: () async {
      final tests = loadTests(config);
      return tests.isEmpty ? 'manifest lists no tests' : null;
    },
    fix: 'fix ${config.testsManifest} in $appDir (see the schema comment '
        'at its top)',
  );

  stdout.writeln(failures == 0
      ? '\ndoctor: all required checks passed'
      : '\ndoctor: $failures required check(s) failed');
  return failures == 0 ? 0 : 1;
}
