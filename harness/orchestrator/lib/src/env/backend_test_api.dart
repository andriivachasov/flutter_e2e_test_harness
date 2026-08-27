import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../users/provisioner.dart';

/// The harness side of the backend's test-only contract (R9b, R16). The
/// backend enables these endpoints only under E2E_TEST_MODE=1, which the
/// orchestrator sets when it starts the backend.
///
/// The enable flag is not an authentication factor: the recommended lock on
/// this surface is that the test backend binds to loopback and rejects
/// non-loopback callers (playbook 03 §3.2). A backend that cannot do that
/// can require a shared secret instead — `backend.test_header` is sent with
/// every request below, and never written to a log or artifact by the
/// harness (issue #7).
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
      // Optional second factor (issue #7). Unset by default: with no
      // `backend.test_header` this loop adds nothing and the request is
      // byte-identical to what the harness has always sent.
      config.backendTestHeaders.headers
          .forEach((name, value) => req.headers.set(name, value));
      req.write(jsonEncode(body));
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode != 200) {
        // The body is the backend's, not ours: a backend that echoes the
        // offending request header in its 403 would otherwise put the
        // configured secret into orchestrator.log verbatim. Scrub every
        // configured value before the message escapes (issue #7 / L1).
        var detail = text;
        for (final secret in config.backendTestHeaders.secretValues) {
          detail = detail.replaceAll(secret, '<redacted>');
        }
        throw StateError('backend test endpoint POST $path failed: '
            'HTTP ${res.statusCode} $detail');
      }
    } finally {
      client.close();
    }
  }
}
