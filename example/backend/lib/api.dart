import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import 'auth.dart';

export 'auth.dart';

/// In-memory API state. One instance per server process.
///
/// Everything is keyed by the signed-in user's EMAIL (proven by the ID
/// token): notes and messages alike. Email — not uid — is the identity
/// because the harness hands out deterministic pool accounts by email and
/// never learns uids (D23). Tests sharded across devices share this one
/// backend (R19a) and stay isolated because every test role has its own
/// account (the X-E2E-Test-Id header is used for log correlation only, R13).
class ApiState {
  final Map<String, List<Map<String, Object?>>> _notesByEmail = {};
  final List<Map<String, Object?>> _messages = [];
  int _nextId = 1;

  String newId() => '${_nextId++}';

  List<Map<String, Object?>> notesFor(String email) =>
      _notesByEmail.putIfAbsent(email, () => []);

  List<Map<String, Object?>> conversation(String a, String b) => _messages
      .where((m) =>
          (m['from'] == a && m['to'] == b) || (m['from'] == b && m['to'] == a))
      .toList();

  Map<String, Object?> addMessage({
    required String from,
    required String to,
    required String text,
  }) {
    final m = {
      'id': newId(),
      'from': from,
      'to': to,
      'text': text,
      'ts': DateTime.now().toUtc().toIso8601String(),
    };
    _messages.add(m);
    return m;
  }

  /// Account-level reset (R9b): everything this user owns or took part in.
  void resetUser({required String email}) {
    _notesByEmail.remove(email);
    _messages.removeWhere((m) => m['from'] == email || m['to'] == email);
  }

  /// Run-level reset: wipe everything.
  void resetAll() {
    _notesByEmail.clear();
    _messages.clear();
  }

  /// Applies a seed profile (R16). The fixture format is this backend's
  /// contract; the harness only transports it:
  ///
  ///   {"notes": ["text", ...],
  ///    "messages": [{"from": "<email>|me", "to": "<email>|me", "text": ".."}]}
  void seed({
    required String email,
    required Map<String, Object?> data,
  }) {
    final notes = data['notes'];
    if (notes is List) {
      for (final n in notes) {
        notesFor(email).add({
          'id': newId(),
          'text': '$n',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'seeded': true,
        });
      }
    }
    final messages = data['messages'];
    if (messages is List) {
      for (final m in messages.whereType<Map>()) {
        String who(Object? v) => (v == null || v == 'me') ? email : '$v';
        addMessage(from: who(m['from']), to: who(m['to']), text: '${m['text']}');
      }
    }
  }
}

/// Rejects `/test/*` requests that did not come from this host (issue #7).
///
/// `E2E_TEST_MODE=1` only *enables* the surface; it is not an authentication
/// factor, and `/test/*` deletes arbitrary user data and must work before an
/// account exists, so it cannot be authenticated the normal way. Loopback is
/// the lock: the harness always calls this surface from the same host, so a
/// non-loopback caller is by definition not the harness.
///
/// Fails CLOSED — an address that is absent (no connection info) or does not
/// parse is refused, not allowed. Pair it with a loopback bind
/// (`bin/server.dart` binds `127.0.0.1`); the filter is what still holds if
/// someone changes the bind address.
///
/// [prefix] must match `backend.seed_path` / `reset_path` / `reset_user_path`
/// if those are moved off `/test/`.
Middleware loopbackOnly({String prefix = '/test/'}) => (inner) => (req) async {
      if (!'/${req.url.path}'.startsWith(prefix)) return inner(req);
      final info = req.context['shelf.io.connection_info'];
      final remote = info is HttpConnectionInfo ? info.remoteAddress : null;
      if (remote == null || !remote.isLoopback) {
        return Response(
          403,
          body: jsonEncode({'error': 'test endpoints are loopback-only'}),
          headers: {'content-type': 'application/json'},
        );
      }
      return inner(req);
    };

/// Builds the API handler.
///
/// Public API (all need `Authorization: Bearer <Firebase ID token>`):
///   GET  /api/me                      -> {"uid","email"}
///   GET  /api/notes                   -> {"notes":[{id,text,createdAt}]}
///   POST /api/notes {"text"}          -> {"note":{...}}
///   GET  /api/messages?with=<email>   -> {"messages":[{id,from,to,text,ts}]}
///   POST /api/messages {"to","text"}  -> {"message":{...}}
/// Unauthenticated:
///   GET  /health                      -> {"status":"ok"}
/// Test-only (403 unless [testMode]; enabled by E2E_TEST_MODE=1, and
/// loopback-only regardless — see [loopbackOnly]):
///   POST /test/seed {"email","profile","data"}  -> {"ok":true}
///   POST /test/reset/user {"email"}             -> {"ok":true}
///   POST /test/reset                                  -> {"ok":true}
///
/// Every request is logged to stdout as one JSON line including the
/// X-E2E-Run-Id / X-E2E-Test-Id headers and the caller's uid, so the
/// orchestrator can slice the backend log per test (log correlation, R13).
Handler buildHandler(
  ApiState state, {
  required bool testMode,
  required TokenVerifier verifyToken,
  void Function(String email)? onUserReset,
}) {
  Response json(Object? body, {int status = 200}) => Response(
        status,
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      );

  Future<Map<String, dynamic>> body(Request req) async {
    final text = await req.readAsString();
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  Future<Response> route(Request req) async {
    final path = '/${req.url.path}';

    if (req.method == 'GET' && path == '/health') {
      return json({'status': 'ok'});
    }

    if (path.startsWith('/test/')) {
      if (!testMode) return json({'error': 'test endpoints disabled'}, status: 403);
      if (req.method != 'POST') return json({'error': 'not found'}, status: 404);
      final b = await body(req);
      switch (path) {
        case '/test/reset':
          state.resetAll();
          return json({'ok': true});
        case '/test/reset/user':
          final email = b['email'];
          if (email is! String || email.isEmpty) {
            return json({'error': 'email required'}, status: 400);
          }
          state.resetUser(email: email);
          onUserReset?.call(email);
          return json({'ok': true});
        case '/test/seed':
          final email = b['email'];
          final data = b['data'];
          if (email is! String || email.isEmpty) {
            return json({'error': 'email required'}, status: 400);
          }
          if (data is! Map<String, dynamic>) {
            return json({'error': 'data must be an object'}, status: 400);
          }
          state.seed(email: email, data: data);
          return json({'ok': true, 'profile': b['profile']});
        default:
          return json({'error': 'not found'}, status: 404);
      }
    }

    if (path.startsWith('/api/')) {
      final auth = req.headers['authorization'] ?? '';
      if (!auth.startsWith('Bearer ')) {
        return json({'error': 'missing bearer token'}, status: 401);
      }
      final user = await verifyToken(auth.substring(7).trim());
      if (user == null || user.email.isEmpty) {
        return json({'error': 'invalid token'}, status: 401);
      }

      if (req.method == 'GET' && path == '/api/me') {
        return json({'uid': user.uid, 'email': user.email});
      }
      if (req.method == 'GET' && path == '/api/notes') {
        return json({'notes': state.notesFor(user.email)});
      }
      if (req.method == 'POST' && path == '/api/notes') {
        final text = (await body(req))['text'];
        if (text is! String || text.trim().isEmpty) {
          return json({'error': 'text required'}, status: 400);
        }
        final note = {
          'id': state.newId(),
          'text': text,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        };
        state.notesFor(user.email).add(note);
        return json({'note': note});
      }
      if (req.method == 'GET' && path == '/api/messages') {
        final partner = req.url.queryParameters['with'];
        if (partner == null || partner.isEmpty) {
          return json({'error': '"with" required'}, status: 400);
        }
        return json({'messages': state.conversation(user.email, partner)});
      }
      if (req.method == 'POST' && path == '/api/messages') {
        final b = await body(req);
        final to = b['to'], text = b['text'];
        if (to is! String || to.isEmpty || text is! String || text.isEmpty) {
          return json({'error': 'to and text required'}, status: 400);
        }
        return json({
          'message': state.addMessage(from: user.email, to: to, text: text),
        });
      }
    }

    return json({'error': 'not found'}, status: 404);
  }

  Middleware logRequests() => (inner) => (req) async {
        final started = DateTime.now();
        final res = await inner(req);
        final line = jsonEncode({
          'ts': started.toUtc().toIso8601String(),
          'method': req.method,
          'path': '/${req.url.path}',
          'status': res.statusCode,
          'runId': req.headers['x-e2e-run-id'],
          'testId': req.headers['x-e2e-test-id'],
          'ms': DateTime.now().difference(started).inMilliseconds,
        });
        // ignore: avoid_print
        print(line);
        return res;
      };

  return const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(loopbackOnly())
      .addHandler(route);
}
