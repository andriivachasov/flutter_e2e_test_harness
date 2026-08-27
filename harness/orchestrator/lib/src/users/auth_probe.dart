import 'dart:convert';
import 'dart:io';

/// Doctor probe (D23): with only the Web API key, ask Identity Toolkit to
/// sign in a canary account. The *kind* of rejection tells us whether the
/// key is valid and email/password sign-in is enabled — no admin access
/// needed. Returns null when everything is usable, else the problem.
Future<String?> probeEmailPasswordSignIn({
  required String identityToolkitUrl,
  required String apiKey,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client
        .postUrl(Uri.parse('$identityToolkitUrl/accounts:signInWithPassword?key=$apiKey'))
        .timeout(timeout);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'email': 'e2e-doctor-canary@e2e.example.com',
      'password': 'canary-Passw0rd-never-registered',
      'returnSecureToken': true,
    }));
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode == 200) return null; // (someone registered the canary)
    final message = (((jsonDecode(text) as Map<String, dynamic>)['error']
            as Map<String, dynamic>?)?['message'] as String?) ??
        'HTTP ${res.statusCode}';
    final code = message.split(' ').first.split(':').first;
    switch (code) {
      case 'EMAIL_NOT_FOUND':
      case 'INVALID_LOGIN_CREDENTIALS':
      case 'INVALID_PASSWORD':
      case 'USER_DISABLED':
        return null; // key accepted, provider enabled, account just absent
      case 'OPERATION_NOT_ALLOWED':
      case 'PASSWORD_LOGIN_DISABLED':
        return 'email/password sign-in is disabled for this project ($code)';
      case 'API_KEY_INVALID':
      case 'INVALID_API_KEY':
        return 'the Web API key is not valid for any project ($code)';
      default:
        return 'unexpected answer from Identity Toolkit: $message';
    }
  } on Object catch (e) {
    return 'cannot reach identitytoolkit.googleapis.com: $e';
  } finally {
    client.close();
  }
}
