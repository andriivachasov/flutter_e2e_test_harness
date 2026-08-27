import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/proc.dart';

/// The Firebase Auth emulator for one run (D2). Started through the
/// `firebase` CLI with a per-run `firebase.json` so every port (auth, hub,
/// logging) is chosen by the orchestrator's allocator — two runs on one
/// machine, or another project's emulator on 9099, never collide.
///
/// Only the Auth emulator is started; it is implemented inside the CLI
/// itself, so no Java runtime is needed (Firestore/Database would need one).
class AuthEmulatorProcess {
  AuthEmulatorProcess._(this._proc, this.port, this.projectId);

  final ManagedProcess _proc;
  final int port;
  final String projectId;
  bool _stopping = false;

  /// Identity Toolkit v1 base as seen from the host.
  String get identityToolkitUrl =>
      'http://127.0.0.1:$port/identitytoolkit.googleapis.com/v1';

  /// Same base, addressed for a device that reaches the host as [host]
  /// (10.0.2.2 on Android emulators, 127.0.0.1 on iOS simulators).
  String identityToolkitUrlFor(String host) =>
      'http://$host:$port/identitytoolkit.googleapis.com/v1';

  /// Completes only if the emulator dies on its own (never on [stop]).
  Future<int> get unexpectedExit async {
    final code = await _proc.exitCode;
    if (_stopping) return Completer<int>().future;
    return code;
  }

  /// Writes `<runDir>/firebase.json`, starts the emulator and waits until
  /// it answers on [port]. Output streams into [logFile] (`firebase.log`,
  /// R12); the CLI's own `firebase-debug.log` lands in [runDir] as well.
  static Future<AuthEmulatorProcess> start({
    required String cli,
    required String projectId,
    required int port,
    required int hubPort,
    required int loggingPort,
    required Directory runDir,
    required File logFile,
    Duration startTimeout = const Duration(seconds: 90),
  }) async {
    if (!projectId.startsWith('demo-')) {
      throw StateError('refusing to start the Auth emulator for non-demo '
          'project "$projectId" (D2: emulator runs must not reach a real '
          'project)');
    }
    final configFile = File('${runDir.path}/firebase.json')
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'emulators': {
          // 0.0.0.0: Android emulators connect via 10.0.2.2, not loopback.
          'auth': {'host': '0.0.0.0', 'port': port},
          'hub': {'port': hubPort},
          'logging': {'port': loggingPort},
          'ui': {'enabled': false},
          'singleProjectMode': true,
        },
      }));

    final proc = await ManagedProcess.start(
      'auth-emulator',
      [
        cli,
        'emulators:start',
        '--only', 'auth',
        '--project', projectId,
        '--config', configFile.path,
        '--non-interactive',
      ],
      cwd: runDir.path,
      environment: {
        ...Platform.environment,
        // No update checks / telemetry prompts in a headless run.
        'CI': 'true',
        'FIREBASE_CLI_PREVIEWS': '',
      },
      logFile: logFile,
    );

    final deadline = DateTime.now().add(startTimeout);
    final url = Uri.parse('http://127.0.0.1:$port/');
    while (true) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        final res = await (await client.getUrl(url)).close();
        final text = await res.transform(utf8.decoder).join();
        client.close();
        if (res.statusCode == 200) {
          final body = jsonDecode(text);
          final ready = body is Map &&
              (body['authEmulator'] as Map?)?['ready'] == true;
          if (ready) return AuthEmulatorProcess._(proc, port, projectId);
        }
      } on Object {
        // keep polling until deadline
      }
      final exited = await proc.exitCode
          .timeout(const Duration(milliseconds: 300), onTimeout: () => -1);
      if (exited != -1) {
        throw StateError('Auth emulator exited with code $exited before '
            'becoming ready — see ${logFile.path}');
      }
      if (DateTime.now().isAfter(deadline)) {
        await proc.stop();
        throw StateError('Auth emulator did not become ready on $url within '
            '${startTimeout.inSeconds}s — see ${logFile.path}');
      }
    }
  }

  Future<void> stop() {
    _stopping = true;
    // The CLI shuts its emulators down on SIGINT; SIGKILL follows if not.
    return _proc.stop(
      signal: ProcessSignal.sigint,
      grace: const Duration(seconds: 15),
    );
  }
}
