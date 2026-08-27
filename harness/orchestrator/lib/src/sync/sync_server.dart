import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// In-memory sync server: barriers, events, kv. Counterpart of the
/// SyncClient in e2e_test_support. State is namespaced by `ns`
/// (runId/testId), so concurrent tests never collide.
class SyncServer {
  final Map<String, Set<String>> _barriers = {};
  final Map<String, Map<String, Object?>> _events = {};
  final Map<String, Object?> _kv = {};

  /// First failure reported per namespace (`ns` -> `{role, message}`).
  /// Waiters poll this alongside their own primitive so a partner's failure
  /// ends their wait immediately instead of at their own deadline (R25).
  /// First writer wins: later reports are cascades of the first one.
  final Map<String, Map<String, String>> _failures = {};

  /// Invoked when a test process asks for a screenshot of its own device
  /// (`POST /artifact/screenshot?ns=<runId>/<testId>&role=..&label=..`).
  /// Returns the path written. The runner wires this to the collector;
  /// unset (or throwing) yields a non-2xx that the client treats as a
  /// degraded artifact, never a test failure.
  Future<String> Function(String ns, String role, String label)?
      onScreenshot;

  /// `POST /harness/seed?ns=..&role=..&profile=..` — apply a seed profile
  /// to the role's user mid-test (R16). Wired by the runner.
  Future<void> Function(String ns, String role, String profile)? onSeed;

  /// `POST /harness/reset-account?ns=..&role=..` — account-level reset of
  /// the role's user (R9b). Wired by the runner.
  Future<void> Function(String ns, String role)? onResetAccount;

  /// `POST /harness/step?ns=..&role=..&name=..` — a test entered a step
  /// (module boundary); R14/R15 bookkeeping.
  void Function(String ns, String role, String name)? onStep;

  /// `POST /harness/failure?ns=..&role=..` body `{"message"}` — the test
  /// is failing; recorded with the step it was in. The first such report
  /// per namespace is also published to the namespace's waiters (R25).
  void Function(String ns, String role, String message)? onFailure;

  HttpServer? _server;
  int get port => _server!.port;

  Future<void> start({int port = 0}) async {
    _server = await shelf_io.serve(
      _handler,
      InternetAddress.anyIPv4, // devices reach us via 10.0.2.2 / 127.0.0.1
      port,
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _handler(Request req) async {
    Response json(Object? body, {int status = 200}) => Response(
          status,
          body: jsonEncode(body),
          headers: {'content-type': 'application/json'},
        );

    final path = '/${req.url.path}';
    final q = req.url.queryParameters;
    final ns = q['ns'] ?? '';
    String key(String name) => '$ns|$name';

    /// Adds `failed: {role, message}` to a body a waiter is still polling,
    /// so it learns about a partner's failure in the request it was already
    /// making — no extra round trip per poll.
    Map<String, Object?> withFailure(Map<String, Object?> body) {
      final f = _failures[ns];
      return f == null ? body : {...body, 'failed': f};
    }

    if (path == '/health') return json({'status': 'ok'});

    if (req.method == 'POST' && path == '/sync/arrive') {
      final name = q['name'], party = q['party'];
      if (name == null || party == null) {
        return json({'error': 'name and party required'}, status: 400);
      }
      final set = _barriers.putIfAbsent(key(name), () => {});
      set.add(party);
      return json({'arrived': set.length});
    }

    if (req.method == 'GET' && path == '/sync/count') {
      final name = q['name'];
      if (name == null) return json({'error': 'name required'}, status: 400);
      return json(withFailure({'count': _barriers[key(name)]?.length ?? 0}));
    }

    if (req.method == 'POST' && path == '/sync/emit') {
      final name = q['name'];
      if (name == null) return json({'error': 'name required'}, status: 400);
      final bodyText = await req.readAsString();
      final data = bodyText.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(bodyText) as Map<String, dynamic>)
              .cast<String, Object?>();
      _events[key(name)] = data;
      return json({'ok': true});
    }

    if (req.method == 'GET' && path == '/sync/event') {
      final name = q['name'];
      if (name == null) return json({'error': 'name required'}, status: 400);
      final data = _events[key(name)];
      if (data == null) {
        return json(withFailure({'error': 'not emitted'}), status: 404);
      }
      return json(data);
    }

    if (req.method == 'POST' && path == '/sync/kv') {
      final k = q['key'];
      if (k == null) return json({'error': 'key required'}, status: 400);
      final body =
          jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      _kv[key(k)] = body['value'];
      return json({'ok': true});
    }

    if (req.method == 'GET' && path == '/sync/kv') {
      final k = q['key'];
      if (k == null) return json({'error': 'key required'}, status: 400);
      if (!_kv.containsKey(key(k))) {
        return json(withFailure({'error': 'not set'}), status: 404);
      }
      return json({'value': _kv[key(k)]});
    }

    if (req.method == 'POST' && path == '/artifact/screenshot') {
      final role = q['role'], label = q['label'] ?? 'shot';
      if (role == null) return json({'error': 'role required'}, status: 400);
      final handler = onScreenshot;
      if (handler == null) {
        return json({'error': 'screenshots not available'}, status: 503);
      }
      try {
        final file = await handler(ns, role, label)
            .timeout(const Duration(seconds: 30));
        return json({'path': file});
      } on Object catch (e) {
        return json({'error': '$e'}, status: 500);
      }
    }

    if (req.method == 'POST' && path == '/harness/step') {
      final role = q['role'], name = q['name'];
      if (role == null || name == null) {
        return json({'error': 'role and name required'}, status: 400);
      }
      onStep?.call(ns, role, name);
      return json({'ok': true});
    }

    if (req.method == 'POST' && path == '/harness/failure') {
      final role = q['role'];
      if (role == null) return json({'error': 'role required'}, status: 400);
      final bodyText = await req.readAsString();
      final message = bodyText.isEmpty
          ? ''
          : '${(jsonDecode(bodyText) as Map<String, dynamic>)['message'] ?? ''}';
      _failures.putIfAbsent(ns, () => {'role': role, 'message': message});
      onFailure?.call(ns, role, message);
      return json({'ok': true});
    }

    if (req.method == 'POST' && path == '/harness/seed') {
      final role = q['role'], profile = q['profile'];
      if (role == null || profile == null) {
        return json({'error': 'role and profile required'}, status: 400);
      }
      final handler = onSeed;
      if (handler == null) {
        return json({'error': 'seeding not available'}, status: 503);
      }
      try {
        await handler(ns, role, profile).timeout(const Duration(seconds: 60));
        return json({'ok': true});
      } on Object catch (e) {
        return json({'error': '$e'}, status: 500);
      }
    }

    if (req.method == 'POST' && path == '/harness/reset-account') {
      final role = q['role'];
      if (role == null) return json({'error': 'role required'}, status: 400);
      final handler = onResetAccount;
      if (handler == null) {
        return json({'error': 'account reset not available'}, status: 503);
      }
      try {
        await handler(ns, role).timeout(const Duration(seconds: 60));
        return json({'ok': true});
      } on Object catch (e) {
        return json({'error': '$e'}, status: 500);
      }
    }

    return json({'error': 'not found'}, status: 404);
  }
}
