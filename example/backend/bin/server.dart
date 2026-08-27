import 'dart:io';

import 'package:e2e_example_backend/api.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Arguments:
///   --port <n>        port to listen on (the orchestrator passes a free one)
///   --host <addr>     bind address; default 127.0.0.1 (see below)
///
/// Binds LOOPBACK by default (issue #7). The `/test/*` surface deletes
/// arbitrary user data and must work before an account exists, so it cannot
/// be authenticated; `E2E_TEST_MODE=1` only enables it. Loopback is the lock
/// — and it costs nothing here, because every caller is on this host: the
/// orchestrator talks to 127.0.0.1 and both device flavours reach the host
/// loopback (Android emulators through the 10.0.2.2 alias, iOS simulators
/// directly). `--host 0.0.0.0` is there for the case that needs it — a
/// physical device on the LAN — and then the `/test/*` surface needs the
/// shared-secret header instead (see playbook 03 §3.2); the loopback filter
/// in `lib/api.dart` keeps holding either way.
///
/// Environment:
///   E2E_TEST_MODE=1   enables the /test/* endpoints (orchestrator only —
///                     a production deployment never sets it)
///   AUTH_BASE_URL     Identity Toolkit v1 base used to verify ID tokens:
///                     emulator  http://127.0.0.1:<port>/identitytoolkit.googleapis.com/v1
///                     real      https://identitytoolkit.googleapis.com/v1
///   AUTH_API_KEY      the project's Web API key (any value for the emulator)
Future<void> main(List<String> args) async {
  var port = 8080;
  var host = '127.0.0.1';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.parse(args[i + 1]);
    }
    if (args[i] == '--host' && i + 1 < args.length) {
      host = args[i + 1];
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
    host == '0.0.0.0'
        ? InternetAddress.anyIPv4
        : InternetAddress.tryParse(host) ??
            (await InternetAddress.lookup(host)).first,
    port,
  );
  // ignore: avoid_print
  print('{"event":"listening","host":"$host","port":${server.port},'
      '"testMode":$testMode,"authBaseUrl":"$authBase"}');
}
