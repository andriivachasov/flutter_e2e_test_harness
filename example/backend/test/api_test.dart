import 'dart:convert';
import 'dart:io';

import 'package:e2e_example_backend/api.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// Token verifier for tests: "tok:<uid>:<email>" is valid, anything else not.
Future<AuthUser?> fakeVerify(String token) async {
  final parts = token.split(':');
  if (parts.length != 3 || parts[0] != 'tok') return null;
  return AuthUser(uid: parts[1], email: parts[2]);
}

void main() {
  late HttpServer server;
  late String base;
  final resets = <String>[];

  setUp(() async {
    resets.clear();
    server = await shelf_io.serve(
      buildHandler(
        ApiState(),
        testMode: true,
        verifyToken: fakeVerify,
        onUserReset: resets.add,
      ),
      InternetAddress.loopbackIPv4,
      0,
    );
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() => server.close(force: true));

  Future<(int, Map<String, dynamic>)> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('$base$path'));
      if (token != null) req.headers.set('authorization', 'Bearer $token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, jsonDecode(text) as Map<String, dynamic>);
    } finally {
      client.close();
    }
  }

  const alice = 'tok:u1:alice@example.com';
  const bob = 'tok:u2:bob@example.com';

  test('health needs no auth', () async {
    final (status, body) = await call('GET', '/health');
    expect(status, 200);
    expect(body['status'], 'ok');
  });

  test('api requires a valid bearer token', () async {
    expect((await call('GET', '/api/me')).$1, 401);
    expect((await call('GET', '/api/me', token: 'garbage')).$1, 401);
    final (status, me) = await call('GET', '/api/me', token: alice);
    expect(status, 200);
    expect(me, {'uid': 'u1', 'email': 'alice@example.com'});
  });

  test('notes are per user', () async {
    final (status, created) =
        await call('POST', '/api/notes', body: {'text': 'hi'}, token: alice);
    expect(status, 200);
    expect((created['note'] as Map)['text'], 'hi');
    expect((await call('POST', '/api/notes', body: {}, token: alice)).$1, 400);

    final (_, mine) = await call('GET', '/api/notes', token: alice);
    expect((mine['notes'] as List).map((n) => (n as Map)['text']), ['hi']);
    final (_, theirs) = await call('GET', '/api/notes', token: bob);
    expect(theirs['notes'], isEmpty);
  });

  test('messages form a two-party conversation', () async {
    await call('POST', '/api/messages',
        body: {'to': 'bob@example.com', 'text': 'hello bob'}, token: alice);
    await call('POST', '/api/messages',
        body: {'to': 'alice@example.com', 'text': 'hi alice'}, token: bob);
    await call('POST', '/api/messages',
        body: {'to': 'carol@example.com', 'text': 'unrelated'}, token: alice);

    final (_, bobView) =
        await call('GET', '/api/messages?with=alice@example.com', token: bob);
    expect(
      (bobView['messages'] as List).map((m) => (m as Map)['text']),
      ['hello bob', 'hi alice'],
    );
    final (_, aliceView) =
        await call('GET', '/api/messages?with=bob@example.com', token: alice);
    expect((aliceView['messages'] as List), hasLength(2));
    expect((await call('GET', '/api/messages', token: alice)).$1, 400);
  });

  test('seed applies a profile and account reset clears only that user',
      () async {
    final (seedStatus, _) = await call('POST', '/test/seed', body: {
      'email': 'alice@example.com',
      'profile': 'user-with-history',
      'data': {
        'notes': ['first', 'second'],
        'messages': [
          {'from': 'bob@example.com', 'to': 'me', 'text': 'old message'},
        ],
      },
    });
    expect(seedStatus, 200);
    await call('POST', '/api/notes', body: {'text': 'bob note'}, token: bob);

    final (_, notes) = await call('GET', '/api/notes', token: alice);
    expect((notes['notes'] as List).map((n) => (n as Map)['text']),
        ['first', 'second']);
    final (_, msgs) =
        await call('GET', '/api/messages?with=bob@example.com', token: alice);
    expect((msgs['messages'] as List).single['from'], 'bob@example.com');

    final (resetStatus, _) = await call('POST', '/test/reset/user',
        body: {'email': 'alice@example.com'});
    expect(resetStatus, 200);
    expect(resets, ['alice@example.com']);
    expect((await call('GET', '/api/notes', token: alice)).$2['notes'], isEmpty);
    expect(
      (await call('GET', '/api/messages?with=bob@example.com', token: alice))
          .$2['messages'],
      isEmpty,
    );
    // Bob's own data survives Alice's reset.
    expect((await call('GET', '/api/notes', token: bob)).$2['notes'],
        hasLength(1));

    // Run-level reset wipes everything.
    await call('POST', '/test/reset');
    expect((await call('GET', '/api/notes', token: bob)).$2['notes'], isEmpty);
  });

  test('seed validates its body', () async {
    expect((await call('POST', '/test/seed', body: {'data': {}})).$1, 400);
    expect(
      (await call('POST', '/test/seed',
              body: {'email': 'a@example.com', 'data': 'x'}))
          .$1,
      400,
    );
  });

  test('test endpoints are forbidden outside test mode', () async {
    final prod = await shelf_io.serve(
      buildHandler(ApiState(), testMode: false, verifyToken: fakeVerify),
      InternetAddress.loopbackIPv4,
      0,
    );
    try {
      for (final path in ['/test/reset', '/test/reset/user', '/test/seed']) {
        final client = HttpClient();
        final req = await client.openUrl(
          'POST',
          Uri.parse('http://127.0.0.1:${prod.port}$path'),
        );
        final res = await req.close();
        expect(res.statusCode, 403, reason: path);
        client.close();
      }
    } finally {
      await prod.close(force: true);
    }
  });
}
