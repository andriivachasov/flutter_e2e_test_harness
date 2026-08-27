import 'dart:convert';
import 'dart:io';

import 'package:e2e_orchestrator/src/sync/sync_server.dart';
import 'package:test/test.dart';

void main() {
  late SyncServer server;
  late String base;

  setUp(() async {
    server = SyncServer();
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() => server.stop());

  Future<(int, Map<String, dynamic>)> call(
    String method,
    String pathAndQuery, {
    Map<String, Object?>? body,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('$base$pathAndQuery'));
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

  test('barrier counts distinct parties', () async {
    final (_, first) = await call('POST', '/sync/arrive?ns=r/t&name=go&party=A');
    expect(first['arrived'], 1);
    // Same party arriving twice does not double count.
    await call('POST', '/sync/arrive?ns=r/t&name=go&party=A');
    final (_, count1) = await call('GET', '/sync/count?ns=r/t&name=go');
    expect(count1['count'], 1);
    await call('POST', '/sync/arrive?ns=r/t&name=go&party=B');
    final (_, count2) = await call('GET', '/sync/count?ns=r/t&name=go');
    expect(count2['count'], 2);
  });

  test('namespaces are isolated', () async {
    await call('POST', '/sync/arrive?ns=run1/t&name=go&party=A');
    final (_, other) = await call('GET', '/sync/count?ns=run2/t&name=go');
    expect(other['count'], 0);
  });

  test('event emit and read', () async {
    final (missing, _) = await call('GET', '/sync/event?ns=r/t&name=sent');
    expect(missing, 404);
    await call('POST', '/sync/emit?ns=r/t&name=sent', body: {'x': 1});
    final (found, data) = await call('GET', '/sync/event?ns=r/t&name=sent');
    expect(found, 200);
    expect(data['x'], 1);
  });

  test('kv put and get', () async {
    final (missing, _) = await call('GET', '/sync/kv?ns=r/t&key=chat');
    expect(missing, 404);
    await call('POST', '/sync/kv?ns=r/t&key=chat', body: {'value': 'c-42'});
    final (found, data) = await call('GET', '/sync/kv?ns=r/t&key=chat');
    expect(found, 200);
    expect(data['value'], 'c-42');
  });

  test('a reported failure rides along on the responses waiters poll',
      () async {
    // The wire shape SyncClient reads. Absent until someone fails, so an
    // older client simply never sees it (see fail_fast_test.dart for the
    // behaviour this drives).
    final (_, before) = await call('GET', '/sync/count?ns=r/t&name=go');
    expect(before.containsKey('failed'), isFalse);

    await call('POST', '/harness/failure?ns=r/t&role=A',
        body: {'message': 'A blew up'});

    for (final path in [
      '/sync/count?ns=r/t&name=go',
      '/sync/event?ns=r/t&name=sent',
      '/sync/kv?ns=r/t&key=chat',
    ]) {
      final (_, body) = await call('GET', path);
      expect(body['failed'], {'role': 'A', 'message': 'A blew up'},
          reason: path);
    }

    // First writer wins: a cascade must not rewrite the cause.
    await call('POST', '/harness/failure?ns=r/t&role=B',
        body: {'message': 'cascade'});
    final (_, after) = await call('GET', '/sync/count?ns=r/t&name=go');
    expect((after['failed']! as Map)['role'], 'A');

    // Namespaced like every other primitive.
    final (_, other) = await call('GET', '/sync/count?ns=r/other&name=go');
    expect(other.containsKey('failed'), isFalse);
  });

  test('screenshot route forwards to the handler and reports failures',
      () async {
    final (unavailable, _) =
        await call('POST', '/artifact/screenshot?ns=r/t&role=A&label=x');
    expect(unavailable, 503);

    final seen = <String>[];
    server.onScreenshot = (ns, role, label) async {
      seen.add('$ns|$role|$label');
      return '/runs/r/t/A/screenshots/01_x.png';
    };
    final (ok, body) =
        await call('POST', '/artifact/screenshot?ns=r/t&role=A&label=x');
    expect(ok, 200);
    expect(body['path'], '/runs/r/t/A/screenshots/01_x.png');
    expect(seen, ['r/t|A|x']);

    server.onScreenshot = (_, __, ___) async => throw StateError('boom');
    final (failed, err) =
        await call('POST', '/artifact/screenshot?ns=r/t&role=A&label=x');
    expect(failed, 500);
    expect(err['error'], contains('boom'));

    final (missingRole, _) =
        await call('POST', '/artifact/screenshot?ns=r/t&label=x');
    expect(missingRole, 400);
  });
}
