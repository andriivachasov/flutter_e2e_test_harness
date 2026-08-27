import 'package:e2e_orchestrator/src/sync/sync_server.dart';
import 'package:e2e_test_support/test_support.dart';
import 'package:test/test.dart';

/// Fail-fast across roles (R25): the real SyncClient against the real
/// SyncServer, so both halves of the wire contract are checked against each
/// other. Every wait here would otherwise run to its own deadline.
void main() {
  late SyncServer server;
  late SyncClient a;
  late SyncClient b;

  TestContext ctx(String role) => TestContext(
        runId: 'r',
        testId: 't',
        role: role,
        backendUrl: '',
        syncUrl: 'http://127.0.0.1:${server.port}',
        parties: 2,
        user: const TestUserCredentials(email: '', password: '', scope: ''),
        authUrl: '',
        apiKey: '',
        runSeq: 0,
      );

  setUp(() async {
    server = SyncServer();
    await server.start();
    a = SyncClient(ctx('A'));
    b = SyncClient(ctx('B'));
  });

  tearDown(() => server.stop());

  test('a partner failure ends a barrier wait immediately', () async {
    await a.reportFailure(StateError('A blew up'));

    final started = DateTime.now();
    await expectLater(
      b.barrier('go', timeout: const Duration(minutes: 5)),
      throwsA(isA<PartnerFailure>()
          .having((e) => e.role, 'role', 'A')
          .having((e) => e.message, 'message', contains('A blew up'))),
    );
    // The point of the feature: not the 5-minute budget.
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
  });

  test('a partner failure ends waitForEvent and waitForValue', () async {
    await a.reportFailure(StateError('A blew up'));
    await expectLater(
      b.waitForEvent('sent', timeout: const Duration(minutes: 5)),
      throwsA(isA<PartnerFailure>().having((e) => e.role, 'role', 'A')),
    );
    await expectLater(
      b.waitForValue('chat', timeout: const Duration(minutes: 5)),
      throwsA(isA<PartnerFailure>().having((e) => e.role, 'role', 'A')),
    );
  });

  test('failing before ever reaching a wait still releases the partner',
      () async {
    // The early-failure race the report calls out: A dies in its first step,
    // before B's first wait even starts. guard publishes from the single
    // wrapping catch, so the marker is already there when B arrives.
    await expectLater(
      a.guard(() async => throw StateError('A died in step one')),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      b.waitForEvent('sent', timeout: const Duration(minutes: 5)),
      throwsA(isA<PartnerFailure>()
          .having((e) => e.role, 'role', 'A')
          .having((e) => e.message, 'message', contains('A died in step one'))),
    );
  });

  test('a role is never released by its own failure', () async {
    await a.reportFailure(StateError('A blew up'));
    // A is unwinding through guard already; its own marker must not turn its
    // remaining waits into PartnerFailure.
    await expectLater(
      a.waitForEvent('sent', timeout: const Duration(milliseconds: 600)),
      throwsA(isA<SyncTimeout>()),
    );
  });

  test('failFast: false opts out and waits to its own deadline', () async {
    await a.reportFailure(StateError('A blew up'));

    await expectLater(
      b.waitForEvent('sent',
          timeout: const Duration(milliseconds: 600), failFast: false),
      throwsA(isA<SyncTimeout>()),
    );

    b.failFast = false;
    await expectLater(
      b.barrier('go', timeout: const Duration(milliseconds: 600)),
      throwsA(isA<SyncTimeout>()),
    );
  });

  test('the first failure wins; a cascade does not rewrite the cause',
      () async {
    await a.reportFailure(StateError('the real cause'));
    await b.reportFailure(StateError('cascade from the partner'));

    final c = SyncClient(ctx('C'));
    await expectLater(
      c.waitForEvent('sent', timeout: const Duration(minutes: 5)),
      throwsA(isA<PartnerFailure>()
          .having((e) => e.role, 'role', 'A')
          .having((e) => e.message, 'message', contains('the real cause'))),
    );
  });

  test('a failure in another test does not release this one', () async {
    final other = SyncClient(TestContext(
      runId: 'r',
      testId: 'other_test',
      role: 'A',
      backendUrl: '',
      syncUrl: 'http://127.0.0.1:${server.port}',
      parties: 2,
      user: const TestUserCredentials(email: '', password: '', scope: ''),
      authUrl: '',
      apiKey: '',
      runSeq: 0,
    ));
    await other.reportFailure(StateError('unrelated'));

    await expectLater(
      b.waitForEvent('sent', timeout: const Duration(milliseconds: 600)),
      throwsA(isA<SyncTimeout>()),
    );
  });

  test('a wait that can be satisfied still succeeds despite a failure marker',
      () async {
    // Data that already arrived wins over the marker: the value B waited for
    // exists, so B proceeds and fails at its next wait instead.
    await a.emit('sent', {'x': 1});
    await a.reportFailure(StateError('A failed after emitting'));

    expect(await b.waitForEvent('sent'), {'x': 1});
    await expectLater(
      b.waitForValue('chat', timeout: const Duration(minutes: 5)),
      throwsA(isA<PartnerFailure>()),
    );
  });
}
