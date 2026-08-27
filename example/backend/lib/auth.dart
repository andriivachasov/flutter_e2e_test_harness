import 'dart:convert';
import 'dart:io';

/// The signed-in caller, as established from a Firebase ID token.
class AuthUser {
  const AuthUser({required this.uid, required this.email});
  final String uid;
  final String email;
}

/// Turns a bearer ID token into an [AuthUser], or null when invalid.
typedef TokenVerifier = Future<AuthUser?> Function(String idToken);

/// Verifies Firebase ID tokens by asking Identity Toolkit itself
/// (`accounts:lookup` with the token). One code path serves both the Auth
/// emulator (unsigned tokens, any API key) and a real project (signed
/// tokens, the project's Web API key) — the example backend therefore needs
/// no JWT/RSA code at all.
///
/// A production backend would verify signatures locally (Firebase Admin
/// SDK); the playbook documents that swap. The verifier caches by token so
/// the app's polling costs one lookup per session, not one per request.
class IdentityToolkitVerifier {
  IdentityToolkitVerifier({
    required this.baseUrl,
    required this.apiKey,
    this.cacheTtl = const Duration(minutes: 10),
    this.timeout = const Duration(seconds: 10),
  });

  /// Identity Toolkit v1 base, e.g.
  /// `http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1` (emulator) or
  /// `https://identitytoolkit.googleapis.com/v1` (real project).
  final String baseUrl;
  final String apiKey;
  final Duration cacheTtl;
  final Duration timeout;

  final Map<String, (AuthUser, DateTime)> _cache = {};

  Future<AuthUser?> verify(String idToken) async {
    final cached = _cache[idToken];
    if (cached != null && DateTime.now().isBefore(cached.$2)) return cached.$1;

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client
          .postUrl(Uri.parse('$baseUrl/accounts:lookup?key=$apiKey'))
          .timeout(timeout);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'idToken': idToken}));
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode != 200) return null;
      final users = (jsonDecode(text) as Map<String, dynamic>)['users'];
      if (users is! List || users.isEmpty) return null;
      final u = users.first as Map<String, dynamic>;
      final uid = u['localId'];
      if (uid is! String || uid.isEmpty) return null;
      final user = AuthUser(uid: uid, email: (u['email'] as String?) ?? '');
      _cache[idToken] = (user, DateTime.now().add(cacheTtl));
      return user;
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }

  /// Forgets cached verdicts for [email] — used by the account reset.
  void forget(String email) =>
      _cache.removeWhere((_, v) => v.$1.email == email);
}
