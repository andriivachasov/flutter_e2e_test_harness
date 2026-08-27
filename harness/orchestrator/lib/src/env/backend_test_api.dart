import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../users/provisioner.dart';

/// The harness side of the backend's test-only contract (R9b, R16). The
/// backend enables these endpoints only under E2E_TEST_MODE=1, which the
/// orchestrator sets when it starts the backend.
///
///   POST <seed_path>        {"email","profile","data"}
///   POST <reset_user_path>  {"email"}
///   POST <reset_path>       (run-level wipe)
class BackendTestApi {
  BackendTestApi({
    required this.baseUrl,
    required this.config,
    this.timeout = const Duration(seconds: 30),
  });

  final String baseUrl;
  final HarnessConfig config;
  final Duration timeout;

  Future<void> seed(TestUser user, String profile, Map<String, Object?> data) =>
      _post(config.backendSeedPath, {
        'email': user.email,
        'profile': profile,
        'data': data,
      });

  Future<void> resetUser(TestUser user) =>
      _post(config.backendResetUserPath, {'email': user.email});

  Future<void> resetAll() => _post(config.backendResetPath, const {});

  Future<void> _post(String path, Map<String, Object?> body) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.postUrl(Uri.parse('$baseUrl$path')).timeout(timeout);
      req.headers.contentType = ContentType.json;
      req.headers.set('X-E2E-Source', 'orchestrator');
      req.write(jsonEncode(body));
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode != 200) {
        throw StateError('backend test endpoint POST $path failed: '
            'HTTP ${res.statusCode} $text');
      }
    } finally {
      client.close();
    }
  }
}
