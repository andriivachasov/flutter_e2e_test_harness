import 'dart:io';

import 'package:e2e_example_backend/api.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Environment:
///   E2E_TEST_MODE=1   enables the /test/* endpoints (orchestrator only —
///                     a production deployment never sets it)
///   AUTH_BASE_URL     Identity Toolkit v1 base used to verify ID tokens:
///                     emulator  http://127.0.0.1:<port>/identitytoolkit.googleapis.com/v1
///                     real      https://identitytoolkit.googleapis.com/v1
///   AUTH_API_KEY      the project's Web API key (any value for the emulator)
Future<void> main(List<String> args) async {
  var port = 8080;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.parse(args[i + 1]);
    }
  }
  final env = Platform.environment;
  final testMode = env['E2E_TEST_MODE'] == '1';
  final authBase =
      env['AUTH_BASE_URL'] ?? 'https://identitytoolkit.googleapis.com/v1';
  final verifier = IdentityToolkitVerifier(
    baseUrl: authBase,
    apiKey: env['AUTH_API_KEY'] ?? 'unset',
  );

  final state = ApiState();
  final server = await shelf_io.serve(
    buildHandler(
      state,
      testMode: testMode,
      verifyToken: verifier.verify,
      onUserReset: verifier.forget,
    ),
    InternetAddress.anyIPv4,
    port,
  );
  // ignore: avoid_print
  print('{"event":"listening","port":${server.port},"testMode":$testMode,'
      '"authBaseUrl":"$authBase"}');
}
