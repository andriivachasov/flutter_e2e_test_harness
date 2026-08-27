import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../util/proc.dart';

/// Starts the backend under test-mode and waits for /health.
class BackendProcess {
  BackendProcess._(this._proc, this.port);

  final ManagedProcess _proc;
  final int port;
  bool _stopping = false;

  /// Completes with the exit code only if the backend dies on its own
  /// (never when [stop] is called): the runner uses this to abort tests
  /// whose environment vanished instead of letting them run to timeout.
  Future<int> get unexpectedExit async {
    final code = await _proc.exitCode;
    if (_stopping) return Completer<int>().future; // never completes
    return code;
  }

  static Future<BackendProcess> start(
    HarnessConfig config, {
    required int port,
    required File logFile,
    Map<String, String> environment = const {},
  }) async {
    // How the port reaches the backend is configurable (`backend.port_flag`,
    // default `["--port", "{port}"]`): not every server takes `--port <n>`.
    final command = [...config.backendCommand, ...config.backendPortArgs(port)];
    final proc = await ManagedProcess.start(
      'backend',
      command,
      cwd: config.resolve(config.backendDir),
      environment: {
        ...Platform.environment,
        ...environment,
        'E2E_TEST_MODE': '1',
      },
      logFile: logFile,
    );

    final deadline = DateTime.now().add(config.backendStartTimeout);
    final url = Uri.parse('http://127.0.0.1:$port${config.backendHealthPath}');
    while (true) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        final req = await client.getUrl(url);
        final res = await req.close();
        await res.transform(utf8.decoder).join();
        client.close();
        if (res.statusCode == 200) return BackendProcess._(proc, port);
      } on Object {
        // keep polling until deadline
      }
      if (DateTime.now().isAfter(deadline)) {
        await proc.stop();
        throw StateError(
          'backend did not become healthy on $url within '
          '${config.backendStartTimeout.inSeconds}s — see ${logFile.path}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> stop() {
    _stopping = true;
    return _proc.stop();
  }
}
