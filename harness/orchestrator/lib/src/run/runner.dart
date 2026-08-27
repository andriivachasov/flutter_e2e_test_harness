import 'dart:async';
import 'dart:io';

import '../artifacts/collector.dart';
import '../artifacts/retention.dart';
import '../artifacts/summary.dart';
import '../config.dart';
import '../devices/android_device.dart';
import '../devices/device.dart';
import '../devices/ios_device.dart';
import '../env/backend_process.dart';
import '../env/backend_test_api.dart';
import '../env/firebase_emulator.dart';
import '../executor/patrol_executor.dart';
import '../seed/seed_loader.dart';
import '../sync/sync_server.dart';
import '../tests/registry.dart';
import '../users/provisioner.dart';
import '../util/ports.dart';

/// What one `run` produced; consumed by `e2e audit`.
class RunResult {
  RunResult({required this.runId, required this.runDir, required this.exitCode});
  final String runId;
  final Directory runDir;
  final int exitCode;
}

/// Per-role bookkeeping of reported steps and the failure (R14/R15).
class _RoleProgress {
  final List<(String, DateTime)> steps = [];
  String? failedStep;
  String? failureMessage;
}

/// Exit codes: 0 = all passed, 1 = test failures, 2 = infra/config error.
class Runner {
  Runner(this.config);

  final HarnessConfig config;
  final List<String> _warnings = [];
  late final IOSink _log;

  /// Set once [run] has created its run directory.
  RunResult? lastResult;

  /// Reads and increments `runs/.seq` (a monotonic per-machine counter).
  int _nextSeq() {
    final f = File('${config.resolve(config.artifactsDir)}/.seq');
    var n = 0;
    try {
      n = int.tryParse(f.readAsStringSync().trim()) ?? 0;
    } on Object {
      // first run
    }
    n += 1;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('$n');
    return n;
  }

  void _info(String msg) {
    final line = '[${DateTime.now().toIso8601String()}] $msg';
    stdout.writeln(line);
    _log.writeln(line);
  }

  void _warn(String msg) {
    _warnings.add(msg);
    _info('WARN: $msg');
  }

  Future<int> run({
    String? testName,
    Set<String>? tags,
    bool keepAll = false,
  }) async {
    final List<TestSpec> allTests;
    final List<TestSpec> specs;
    try {
      allTests = loadTests(config);
      specs = selectTests(allTests, testName: testName, tags: tags);
    } on ConfigError catch (e) {
      stderr.writeln('$e');
      return 2;
    }
    if (specs.isEmpty) {
      stderr.writeln('no tests match '
          '${testName ?? tags?.join(',') ?? '(all)'} — see `e2e list`');
      return 2;
    }
    final configProblems = [
      ...config.firebase.validate(),
      if (specs.any((s) => s.seeds.isNotEmpty) && !config.hasBackend)
        'the selection declares seed profiles but backend.command is empty '
            '(no backend to seed)',
      if (specs.any((s) => s.seeds.isNotEmpty) && config.firebase.isNone)
        'the selection declares seed profiles but firebase.mode is "none" '
            '(seeds attach to a provisioned user)',
    ];
    if (configProblems.isNotEmpty) {
      stderr.writeln('config problems (see `e2e doctor`):\n  '
          '${configProblems.join('\n  ')}');
      return 2;
    }

    final startedAt = DateTime.now();
    final runId =
        '${startedAt.toIso8601String().replaceAll(RegExp(r'[:.]'), '').substring(0, 15)}'
        '_${startedAt.millisecondsSinceEpoch % 1000}';
    final runDir = Directory(
      '${config.resolve(config.artifactsDir)}/$runId',
    )..createSync(recursive: true);
    final seq = _nextSeq();
    _log = File('${runDir.path}/orchestrator.log').openWrite();
    _info('run $runId (seq $seq) → ${runDir.path}');
    _info('tests: ${specs.map((s) => s.name).join(', ')}');
    _info('firebase: ${config.firebase.toRedactedJson()} '
        'pool: <scope>-<role>@${config.provisioner.emailDomain}');

    final ports = PortAllocator();
    BackendProcess? backend;
    AuthEmulatorProcess? authEmulator;
    PoolProvisioner? provisioner;
    final sync = SyncServer();
    final outcomes = <TestOutcome>[];
    final timings = RunTimings();
    // Completes when the environment dies mid-run; every test process is
    // torn down through it (R6: no hang, non-zero exit, artifacts intact).
    final abort = Completer<void>();
    String? abortReason;
    void abortRun(String reason) {
      if (abort.isCompleted) return;
      abortReason = reason;
      _warn('aborting run: $reason');
      abort.complete();
    }

    var exitCode = 2;
    try {
      // 1. Firebase Auth: the emulator (D2), the real test project (D6), or
      //    nothing at all (`none`: the app has no Firebase Auth).
      String hostAuthUrl = '';
      if (config.firebase.isNone) {
        _info('firebase.mode is none: no Auth emulator, no test users');
      } else if (config.firebase.isEmulator) {
        final authPort = config.firebase.authEmulatorPort != 0
            ? config.firebase.authEmulatorPort
            : await ports.next();
        _info('starting Firebase Auth emulator on port $authPort');
        final t0 = DateTime.now();
        authEmulator = await AuthEmulatorProcess.start(
          cli: config.firebase.cli,
          projectId: config.firebase.emulatorProjectId,
          port: authPort,
          hubPort: await ports.next(),
          loggingPort: await ports.next(),
          runDir: runDir,
          logFile: File('${runDir.path}/firebase.log'),
        );
        timings.authEmulatorStartMs =
            DateTime.now().difference(t0).inMilliseconds;
        authEmulator.unexpectedExit.then((code) {
          abortRun('Firebase Auth emulator exited unexpectedly with code '
              '$code (see firebase.log)');
        }).ignore();
        hostAuthUrl = authEmulator.identityToolkitUrl;
      } else {
        hostAuthUrl = 'https://identitytoolkit.googleapis.com/v1';
        _info('using real Firebase project '
            '${config.firebase.toRedactedJson()['projectId']}');
      }
      final apiKey = config.firebase.effectiveApiKey;

      // 2. Backend (unless backend.command is empty) + sync server.
      int? backendPort;
      BackendTestApi? backendApi;
      if (config.hasBackend) {
        backendPort = await ports.next();
        _info('starting backend on port $backendPort');
        final backendStart = DateTime.now();
        backend = await BackendProcess.start(
          config,
          port: backendPort,
          logFile: File('${runDir.path}/backend.log'),
          environment: {
            if (hostAuthUrl.isNotEmpty) 'AUTH_BASE_URL': hostAuthUrl,
            'AUTH_API_KEY': apiKey,
          },
        );
        timings.backendStartMs =
            DateTime.now().difference(backendStart).inMilliseconds;
        backend.unexpectedExit.then((code) {
          abortRun('backend exited unexpectedly with code $code '
              '(see backend.log)');
        }).ignore();
        backendApi = BackendTestApi(
          baseUrl: 'http://127.0.0.1:$backendPort',
          config: config,
        );
      } else {
        _info('backend.command is empty: no backend started');
      }
      await sync.start();
      _info('sync server on port ${sync.port}');
      final seeds = SeedLoader(Directory(config.resolve(config.seedsDir)));

      // 3. Users (R10, D23): a deterministic pool; the app registers the
      //    accounts itself. Nothing to prepare.
      provisioner = config.firebase.isNone
          ? null
          : PoolProvisioner(
              emailDomain: config.provisioner.emailDomain,
              password: config.provisioner.poolPassword,
            );

      // 4. Devices. Fixed-platform roles need their platform; `any` roles
      //    can use every platform this host supports (R1: Android-only on
      //    Linux). Boot everything needed, in parallel, timing each boot.
      final hostPlatforms = {
        if (Platform.isMacOS) DevicePlatform.ios,
        DevicePlatform.android,
      };
      final needed = <DevicePlatform>{
        for (final s in specs) ...s.fixedPlatforms,
        if (specs.any((s) => s.roles.any((r) => r.platform == null)))
          ...hostPlatforms,
      }.intersection(hostPlatforms);
      final managers = <DevicePlatform, DeviceManager>{
        if (needed.contains(DevicePlatform.ios))
          DevicePlatform.ios: IosDeviceManager(
            deviceName: config.iosDeviceName,
            bundleId: config.iosBundleId,
          ),
        if (needed.contains(DevicePlatform.android))
          DevicePlatform.android: AndroidDeviceManager(
            avdName: config.androidAvd,
            package: config.androidPackage,
            gpu: config.androidGpu,
          ),
      };
      _info('booting devices: ${needed.map((p) => p.name).join(', ')}');
      final handles = <DevicePlatform, DeviceHandle>{};
      await Future.wait(managers.entries.map((e) async {
        final t0 = DateTime.now();
        handles[e.key] = await e.value.ensureReady();
        timings.deviceBootMs[e.key.name] =
            DateTime.now().difference(t0).inMilliseconds;
        _info('ready: ${handles[e.key]} '
            '(${timings.deviceBootMs[e.key.name]} ms)');
      }));

      final collector = ArtifactCollector(
        runDir: runDir,
        warn: _warn,
        appLaunchTimeout: config.testTimeout,
        captureVideo: config.captureVideo,
      );
      final executor = PatrolExecutor(config);
      executor.prepareBundle(allTests);

      // Test-requested services (R13 screenshots, R16 seeding, R9b account
      // reset) arrive through the sync server, keyed by namespace so
      // concurrently running tests stay separate.
      final activeCaptures = <String, Map<String, DeviceCapture>>{};
      final activeUsers = <String, Map<String, TestUser>>{};
      final activeProgress = <String, Map<String, _RoleProgress>>{};
      sync.onStep = (ns, role, name) {
        activeProgress[ns]?[role]?.steps.add((name, DateTime.now()));
      };
      sync.onFailure = (ns, role, message) {
        final p = activeProgress[ns]?[role];
        if (p == null) return;
        p.failedStep = p.steps.isEmpty ? null : p.steps.last.$1;
        p.failureMessage = message;
      };
      sync.onScreenshot = (ns, role, label) async {
        final capture = activeCaptures[ns]?[role];
        if (capture == null) {
          throw StateError('no active capture for $ns role $role');
        }
        try {
          final file = await collector.screenshot(capture, label);
          _info('screenshot ${ns.split('/').last}/$role: '
              '${file.uri.pathSegments.last}');
          return file.path;
        } on Object catch (e) {
          _warn('screenshot "$label" failed for ${ns.split('/').last}/$role: $e');
          rethrow;
        }
      };
      final api = backendApi;
      if (provisioner != null && api != null) {
        // Pool accounts persist across runs on a persistent backend: start
        // the run with every account this run will use wiped server-side.
        for (final s in specs) {
          for (final r in s.roles) {
            await api.resetUser(provisioner.acquire(
              UserSpec(scope: s.scopeFor(r.role), role: r.role),
            ));
          }
        }
      }
      sync.onSeed = (ns, role, profile) async {
        final user = activeUsers[ns]?[role];
        if (api == null) throw StateError('no backend configured (backend.command is empty)');
        if (user == null) throw StateError('no test user for $ns role $role (firebase.mode none?)');
        await api.seed(user, profile, seeds.load(profile));
        _info('seeded ${ns.split('/').last}/$role with "$profile" (mid-test)');
      };
      sync.onResetAccount = (ns, role) async {
        final user = activeUsers[ns]?[role];
        if (api == null) throw StateError('no backend configured (backend.command is empty)');
        if (user == null) throw StateError('no test user for $ns role $role (firebase.mode none?)');
        await api.resetUser(user);
        _info('account reset ${ns.split('/').last}/$role (mid-test)');
      };

      // 5. Schedule tests over the device pool (R19): a test runs as soon
      //    as every role has a free device; independent tests overlap.
      final freeDevices = Map<DevicePlatform, DeviceHandle>.of(handles);
      final pending = List<TestSpec>.of(specs);
      final running = <Future<TestOutcome>>[];

      Map<String, DeviceHandle>? assign(TestSpec spec) {
        final free = Map<DevicePlatform, DeviceHandle>.of(freeDevices);
        final plan = <String, DeviceHandle>{};
        for (final role in spec.roles.where((r) => r.platform != null)) {
          final d = free.remove(role.platform);
          if (d == null) return null;
          plan[role.role] = d;
        }
        for (final role in spec.roles.where((r) => r.platform == null)) {
          if (free.isEmpty) return null;
          final platform = free.keys.first;
          plan[role.role] = free.remove(platform)!;
        }
        return plan;
      }

      while (pending.isNotEmpty || running.isNotEmpty) {
        if (abort.isCompleted) {
          // Environment is gone: nothing further can run.
          for (final spec in pending) {
            outcomes.add(_infraOutcome(spec, abortReason!));
          }
          pending.clear();
        }
        for (final spec in List.of(pending)) {
          final unavailable = spec.fixedPlatforms.difference(handles.keys.toSet());
          if (unavailable.isNotEmpty) {
            pending.remove(spec);
            outcomes.add(_infraOutcome(
              spec,
              'platform ${unavailable.map((p) => p.name).join(', ')} not '
              'available on this host',
            ));
            continue;
          }
          final plan = assign(spec);
          if (plan == null) continue;
          pending.remove(spec);
          for (final d in plan.values) {
            freeDevices.remove(d.platform);
          }
          _info('scheduling ${spec.name} on '
              '${plan.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
          late Future<TestOutcome> fut;
          fut = _runTest(
            spec: spec,
            plan: plan,
            runId: runId,
            runDir: runDir,
            backendPort: backendPort,
            sync: sync,
            ports: ports,
            collector: collector,
            executor: executor,
            managers: managers,
            activeCaptures: activeCaptures,
            activeUsers: activeUsers,
            activeProgress: activeProgress,
            seq: seq,
            provisioner: provisioner,
            backendApi: backendApi,
            seeds: seeds,
            authEmulator: authEmulator,
            apiKey: apiKey,
            abort: abort.future,
            abortReason: () => abortReason,
          ).whenComplete(() {
            for (final d in plan.values) {
              freeDevices[d.platform] = d;
            }
            running.remove(fut);
          });
          running.add(fut);
        }
        if (running.isEmpty) {
          if (pending.isNotEmpty) {
            // Nothing runs and nothing can be assigned: impossible plans
            // (e.g. more `any` roles than devices).
            for (final spec in pending) {
              outcomes.add(_infraOutcome(
                spec,
                'needs ${spec.roles.length} devices, only ${handles.length} '
                'configured',
              ));
            }
            pending.clear();
          }
          continue;
        }
        outcomes.add(await Future.any(running));
      }

      if (abort.isCompleted) {
        exitCode = 2;
      } else {
        // Quarantined failures are reported but do not block (R14).
        exitCode = outcomes.every((o) => !o.blocking) ? 0 : 1;
        for (final o in outcomes.where((o) => !o.passed && o.quarantined)) {
          _warn('quarantined test ${o.name} failed (tag '
              '"${config.quarantineTag}"): not counted against the run');
        }
      }
      return exitCode;
    } on Object catch (e, st) {
      _warn('run aborted: $e\n$st');
      exitCode = 2;
      return exitCode;
    } finally {
      await sync.stop();
      await backend?.stop();
      await authEmulator?.stop();
      _sliceBackendLog(runDir, outcomes);
      writeSummary(
        runDir: runDir,
        runId: runId,
        startedAt: startedAt,
        outcomes: outcomes,
        warnings: _warnings,
        timings: timings,
        exitCode: exitCode,
        seq: seq,
        environment: {
          'firebase': config.firebase.toRedactedJson(),
          'provisioner': {
            'mode': 'pool',
            'emailDomain': config.provisioner.emailDomain,
          },
          // Names only, values as presence flags (issue #7). Omitted when
          // unset, so summaries of setups without a shared secret keep
          // exactly the shape they had.
          if (config.backendTestHeaders.isNotEmpty)
            'backendTestHeaders': config.backendTestHeaders.toRedactedJson(),
          'resetAppData': config.resetAppData,
          'quarantineTag': config.quarantineTag,
        },
      );
      lastResult = RunResult(runId: runId, runDir: runDir, exitCode: exitCode);
      _info('summary: ${runDir.path}/summary.html');
      _info('result: ${outcomes.where((o) => o.passed).length}/'
          '${outcomes.length} passed, exit $exitCode');
      await _log.flush();
      await _log.close();
      if (!keepAll) {
        final root = Directory(config.resolve(config.artifactsDir));
        for (final removed in pruneRuns(root, keep: config.keepRuns)) {
          stdout.writeln('pruned old run: $removed');
        }
        for (final removed in pruneAudits(root, keep: config.keepAudits)) {
          stdout.writeln('pruned old audit: $removed');
        }
      }
    }
  }

  TestOutcome _infraOutcome(TestSpec spec, String error) {
    final now = DateTime.now();
    return TestOutcome(
      name: spec.name,
      tags: spec.tags,
      roles: const [],
      startedAt: now,
      finishedAt: now,
      infraError: error,
    );
  }

  Future<TestOutcome> _runTest({
    required TestSpec spec,
    required Map<String, DeviceHandle> plan,
    required String runId,
    required Directory runDir,
    required int? backendPort,
    required SyncServer sync,
    required PortAllocator ports,
    required ArtifactCollector collector,
    required PatrolExecutor executor,
    required Map<DevicePlatform, DeviceManager> managers,
    required Map<String, Map<String, DeviceCapture>> activeCaptures,
    required Map<String, Map<String, TestUser>> activeUsers,
    required Map<String, Map<String, _RoleProgress>> activeProgress,
    required int seq,
    required PoolProvisioner? provisioner,
    required BackendTestApi? backendApi,
    required SeedLoader seeds,
    required AuthEmulatorProcess? authEmulator,
    required String apiKey,
    required Future<void> abort,
    required String? Function() abortReason,
  }) async {
    final startedAt = DateTime.now();
    final ns = '$runId/${spec.name}';
    final captures = <String, DeviceCapture>{};
    final users = <String, TestUser>{};
    final progress = <String, _RoleProgress>{
      for (final role in spec.roles) role.role: _RoleProgress(),
    };
    final quarantined = spec.tags.contains(config.quarantineTag);
    activeCaptures[ns] = captures;
    activeUsers[ns] = users;
    activeProgress[ns] = progress;
    _info('=== test ${spec.name} ===');
    var provisionMs = 0;
    try {
      // Preconditions (R8), in order: a pool account per role (R10), its
      // server-side data reset (R9b; accounts are reused across runs) and
      // seeded (R16), then a cold app on the device (R9a).
      final t0 = DateTime.now();
      if (provisioner != null) {
        for (final role in spec.roles) {
          final user = provisioner.acquire(
            UserSpec(scope: spec.scopeFor(role.role), role: role.role),
          );
          users[role.role] = user;
          if (backendApi != null) await backendApi.resetUser(user);
          final profile = spec.seeds[role.role];
          if (profile != null) {
            await backendApi!.seed(user, profile, seeds.load(profile));
          }
          _info('${spec.name}/${role.role}: user ${user.email}'
              '${profile == null ? '' : ' seeded with "$profile"'}');
        }
      }
      provisionMs = DateTime.now().difference(t0).inMilliseconds;

      for (final role in spec.roles) {
        final device = plan[role.role]!;
        if (config.resetAppData) {
          await managers[device.platform]!.clearAppData(device);
        }
        captures[role.role] = await collector.beginDevice(
          spec.name,
          role.role,
          device,
          managers[device.platform]!,
        );
      }

      // Patrol's per-session ports must differ per concurrent role (see
      // PatrolExecutor.runRole); allocate them all before launching.
      final patrolPorts = <String, (int, int)>{
        for (final role in spec.roles)
          role.role: (await ports.next(), await ports.next()),
      };
      final roleStartedAt = DateTime.now();
      final results = await Future.wait(spec.roles.map((role) {
        final device = plan[role.role]!;
        final (testServerPort, appServerPort) = patrolPorts[role.role]!;
        final user = users[role.role];
        _info('launching ${spec.name} role=${role.role} on $device '
            '(patrol ports $testServerPort/$appServerPort)');
        return executor.runRole(
          spec: spec,
          role: role,
          device: device,
          runId: runId,
          backendPort: backendPort,
          syncPort: sync.port,
          testServerPort: testServerPort,
          appServerPort: appServerPort,
          testLog: File('${runDir.path}/${spec.name}/${role.role}/test.log'),
          extraDefines: {
            if (user != null) ...{
              'E2E_AUTH_URL': authEmulator?.identityToolkitUrlFor(device.loopbackHost) ??
                  'https://identitytoolkit.googleapis.com/v1',
              'E2E_FIREBASE_API_KEY': apiKey,
              'E2E_USER_EMAIL': user.email,
              'E2E_USER_PASSWORD': user.password,
              'E2E_USER_SCOPE': user.scope,
            },
            'E2E_RUN_SEQ': '$seq',
          },
          secretDefines: const {'E2E_USER_PASSWORD', 'E2E_FIREBASE_API_KEY'},
          abort: abort,
        );
      }));

      final finishedAt = DateTime.now();
      List<StepTiming> stepsOf(String role) {
        final steps = progress[role]!.steps;
        return [
          for (var i = 0; i < steps.length; i++)
            StepTiming(
              name: steps[i].$1,
              startedAt: steps[i].$2,
              durationMs: (i + 1 < steps.length ? steps[i + 1].$2 : finishedAt)
                  .difference(steps[i].$2)
                  .inMilliseconds,
            ),
        ];
      }

      final outcome = TestOutcome(
        name: spec.name,
        tags: spec.tags,
        startedAt: startedAt,
        finishedAt: finishedAt,
        infraError: results.any((r) => r.aborted) ? abortReason() : null,
        provisionMs: provisionMs,
        quarantined: quarantined,
        roles: [
          for (var i = 0; i < spec.roles.length; i++)
            RoleOutcome(
              role: spec.roles[i].role,
              platform: plan[spec.roles[i].role]!.platform.name,
              deviceDescription: plan[spec.roles[i].role]!.toString(),
              passed: results[i].passed,
              timedOut: results[i].timedOut,
              aborted: results[i].aborted,
              exitCode: results[i].exitCode,
              durationMs: results[i].duration.inMilliseconds,
              artifactDir: '${spec.name}/${spec.roles[i].role}',
              user: users[spec.roles[i].role]?.toJson(),
              seedProfile: spec.seeds[spec.roles[i].role],
              steps: stepsOf(spec.roles[i].role),
              failedStep: results[i].passed
                  ? null
                  : progress[spec.roles[i].role]!.failedStep ??
                      (progress[spec.roles[i].role]!.steps.isEmpty
                          ? null
                          : progress[spec.roles[i].role]!.steps.last.$1),
              failureMessage: results[i].passed
                  ? null
                  : progress[spec.roles[i].role]!.failureMessage ??
                      (results[i].timedOut
                          ? 'timed out'
                          : results[i].aborted
                              ? 'aborted by orchestrator'
                              : null),
              appLaunchMs: captures[spec.roles[i].role]
                  ?.appLaunchedAt
                  ?.difference(roleStartedAt)
                  .inMilliseconds,
            ),
        ],
      );
      _info('test ${spec.name}: ${outcome.verdict}'
          '${quarantined && !outcome.passed ? ' (quarantined)' : ''}');
      return outcome;
    } on Object catch (e) {
      _warn('infra error in ${spec.name}: $e');
      return TestOutcome(
        name: spec.name,
        tags: spec.tags,
        roles: const [],
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        infraError: '$e',
        provisionMs: provisionMs,
        quarantined: quarantined,
      );
    } finally {
      activeCaptures.remove(ns);
      activeUsers.remove(ns);
      activeProgress.remove(ns);
      for (final capture in captures.values) {
        await collector.endDevice(capture);
      }
      // Leave the accounts' server-side data clean for the next run (R9b).
      for (final user in users.values) {
        try {
          await backendApi?.resetUser(user).timeout(const Duration(seconds: 30));
        } on Object catch (e) {
          _warn('data cleanup for ${user.email} failed: $e');
        }
      }
    }
  }

  /// R13: per-test backend.log slice, selected by the X-E2E-Test-Id the app
  /// sends on every request (the backend echoes it as `testId`).
  void _sliceBackendLog(Directory runDir, List<TestOutcome> outcomes) {
    final full = File('${runDir.path}/backend.log');
    if (!full.existsSync()) return;
    final lines = full.readAsLinesSync();
    for (final o in outcomes) {
      final needle = '"testId":"${o.name}"';
      final dir = Directory('${runDir.path}/${o.name}')
        ..createSync(recursive: true);
      File('${dir.path}/backend.log').writeAsStringSync(
        lines.where((l) => l.contains(needle)).map((l) => '$l\n').join(),
      );
    }
  }
}
