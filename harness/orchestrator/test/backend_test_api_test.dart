import 'dart:convert';
import 'dart:io';

import 'package:e2e_orchestrator/src/config.dart';
import 'package:e2e_orchestrator/src/env/backend_test_api.dart';
import 'package:e2e_orchestrator/src/users/provisioner.dart';
import 'package:test/test.dart';

/// Issue #7: the `/test/*` surface has no second authentication factor. The
/// documented lock is a loopback-only backend (playbook 03 §3.2); this file
/// covers the optional alternative — `backend.test_header`, a shared secret
/// the orchestrator sends with every `/test/*` request — and the rule that
/// its value never leaves the process except on that request.
void main() {
  /// A stub backend that records the headers of every request it answers.
  Future<(HttpServer, List<HttpHeaders>)> stubBackend() async {
    final seen = <HttpHeaders>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      seen.add(req.headers);
      await req.drain<void>();
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true}));
      await req.response.close();
    });
    return (server, seen);
  }

  HarnessConfig configWith(String yaml) {
    final dir = Directory.systemTemp.createTempSync('e2e_test_header');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/e2e.yaml').writeAsStringSync(yaml);
    return HarnessConfig.load('${dir.path}/e2e.yaml', env: const {});
  }

  const secret = 'sh4red-secret-value';
  final user = TestUser(
    email: 'chat-a@e2e.example.com',
    password: 'pw',
    scope: 'chat',
    role: 'a',
  );

  group('backend.test_header (issue #7)', () {
    test('unset by default: only the headers the harness always sent',
        () async {
      final (server, seen) = await stubBackend();
      addTearDown(() => server.close(force: true));
      final config = configWith('run:\n');
      expect(config.backendTestHeaders.isEmpty, isTrue);

      await BackendTestApi(
        baseUrl: 'http://127.0.0.1:${server.port}',
        config: config,
      ).resetAll();

      expect(seen, hasLength(1));
      expect(seen.single.value('x-e2e-source'), 'orchestrator');
      expect(seen.single.value('x-e2e-test-secret'), isNull);
      final names = <String>[];
      seen.single.forEach((n, _) => names.add(n));
      expect(
        names.where((n) => n.startsWith('x-')),
        ['x-e2e-source'],
        reason: 'no extra headers when no secret is configured',
      );
    });

    test('name/value form is sent on every /test/* request', () async {
      final (server, seen) = await stubBackend();
      addTearDown(() => server.close(force: true));
      final config = configWith('''
backend:
  test_header:
    name: X-E2E-Test-Secret
    value: "$secret"
''');
      final api = BackendTestApi(
        baseUrl: 'http://127.0.0.1:${server.port}',
        config: config,
      );

      await api.resetAll();
      await api.resetUser(user);
      await api.seed(user, 'profile', const {'notes': []});

      expect(seen, hasLength(3));
      for (final headers in seen) {
        expect(headers.value('x-e2e-test-secret'), secret);
        expect(headers.value('x-e2e-source'), 'orchestrator');
      }
    });

    test('map form sends every configured header', () async {
      final (server, seen) = await stubBackend();
      addTearDown(() => server.close(force: true));
      final config = configWith('''
backend:
  test_header:
    X-E2E-Test-Secret: "$secret"
    X-Env: staging
''');

      await BackendTestApi(
        baseUrl: 'http://127.0.0.1:${server.port}',
        config: config,
      ).resetAll();

      expect(seen.single.value('x-e2e-test-secret'), secret);
      expect(seen.single.value('x-env'), 'staging');
    });

    test('reaches the config through e2e.local.yaml and E2E_* overrides', () {
      final dir = Directory.systemTemp.createTempSync('e2e_test_header_layer');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/e2e.yaml').writeAsStringSync('run:\n');
      File('${dir.path}/e2e.local.yaml').writeAsStringSync('''
backend:
  test_header:
    name: X-E2E-Test-Secret
    value: "$secret"
''');

      final local = HarnessConfig.load('${dir.path}/e2e.yaml', env: const {});
      expect(local.backendTestHeaders.headers, {'X-E2E-Test-Secret': secret});

      final env = HarnessConfig.load('${dir.path}/e2e.yaml', env: const {
        'E2E_BACKEND_TEST_HEADER': 'X-Other',
        'E2E_BACKEND_TEST_HEADER_VALUE': 'from-env',
      });
      expect(env.backendTestHeaders.headers, {'X-Other': 'from-env'});
    });

    test('a half-configured header is a config error', () {
      expect(
        () => configWith('backend:\n  test_header:\n    name: X-Secret\n'),
        throwsA(isA<ConfigError>()),
      );
      expect(
        () => configWith('backend:\n  test_header: "just-a-string"\n'),
        throwsA(isA<ConfigError>()),
      );
    });
  });

  group('the value is a secret', () {
    late HarnessConfig config;
    setUp(() {
      config = configWith('''
backend:
  test_header:
    name: X-E2E-Test-Secret
    value: "$secret"
''');
    });

    test('the redacted form keeps names and drops values', () {
      final redacted = config.backendTestHeaders.toRedactedJson();
      expect(redacted, {'X-E2E-Test-Secret': '<set>'});
      expect(jsonEncode(redacted), isNot(contains(secret)));
      expect(config.backendTestHeaders.toString(), isNot(contains(secret)));
    });

    test('the summary.json environment block never carries the value', () {
      // Same shape the runner writes (runner.dart, `environment:`).
      final environment = <String, Object?>{
        'firebase': config.firebase.toRedactedJson(),
        'provisioner': {
          'mode': 'pool',
          'emailDomain': config.provisioner.emailDomain,
        },
        if (config.backendTestHeaders.isNotEmpty)
          'backendTestHeaders': config.backendTestHeaders.toRedactedJson(),
        'resetAppData': config.resetAppData,
      };
      expect(jsonEncode(environment), isNot(contains(secret)));
      expect(environment['backendTestHeaders'], {'X-E2E-Test-Secret': '<set>'});
    });

    test('it is offered to the subprocess-output redaction pass', () {
      // The executor scrubs these values out of test.log the same way it
      // scrubs E2E_USER_PASSWORD / E2E_FIREBASE_API_KEY.
      expect(config.backendTestHeaders.secretValues, [secret]);
      final line = 'POST /test/reset X-E2E-Test-Secret: $secret';
      var redacted = line;
      for (final v in config.backendTestHeaders.secretValues) {
        redacted = redacted.replaceAll(v, '<redacted>');
      }
      expect(redacted, isNot(contains(secret)));
    });

    // L1: the failure path interpolates the backend's own response body into
    // a StateError that lands in orchestrator.log. A backend that echoes the
    // offending header in its 403 would otherwise leak the secret there.
    test('a backend error body that echoes the secret is scrubbed', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        await req.drain<void>();
        req.response
          ..statusCode = 403
          ..write(jsonEncode({
            'error': 'bad test secret',
            'received': {'X-E2E-Test-Secret': secret},
          }));
        await req.response.close();
      });

      final config = configWith('backend:\n'
          '  test_header:\n'
          '    name: X-E2E-Test-Secret\n'
          '    value: $secret\n');

      await expectLater(
        BackendTestApi(
          baseUrl: 'http://127.0.0.1:${server.port}',
          config: config,
        ).resetAll(),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', isNot(contains(secret)))
            .having((e) => e.message, 'message', contains('<redacted>'))
            .having((e) => e.message, 'message', contains('HTTP 403'))),
      );
    });
  });
}
