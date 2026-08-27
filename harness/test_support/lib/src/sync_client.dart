import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'context.dart';

/// Thrown when a sync operation exceeds its timeout.
class SyncTimeout implements Exception {
  SyncTimeout(this.message);
  final String message;
  @override
  String toString() => 'SyncTimeout: $message';
}

/// Thrown when a wait ends early because ANOTHER role in the same test
/// failed. The role and message name the true cause, so the first error a
/// reader sees is not this process's own timeout.
class PartnerFailure implements Exception {
  PartnerFailure(this.role, this.message);

  /// The role that actually failed — not the role that threw this.
  final String role;

  /// That role's failure message.
  final String message;

  @override
  String toString() => 'PartnerFailure: role "$role" failed: $message';
}

/// Client for the orchestrator's sync server (barriers, events, kv).
///
/// Transport is plain HTTP polling — no held connections, no dependencies.
/// Never use sleep()-based coordination in tests; use these primitives.
class SyncClient {
  SyncClient(this.ctx) : _ns = '${ctx.runId}/${ctx.testId}';

  final TestContext ctx;
  final String _ns;
  final Duration pollInterval = const Duration(milliseconds: 300);

  /// Ends a wait as soon as another role in this test reports a failure,
  /// throwing [PartnerFailure] instead of polling to this role's own
  /// deadline and throwing a [SyncTimeout] that names this role.
  ///
  /// On by default. Set it false (or pass `failFast: false` to a single
  /// wait) in a test that legitimately expects a partner to fail.
  bool failFast = true;

  /// Reads the `failed` marker the sync server attaches to a waiter's
  /// response. Null when absent, when fail-fast is off, or when the failing
  /// role is this one — that role is already unwinding through [guard].
  PartnerFailure? _partnerFailure(String text, bool enabled) {
    if (!enabled) return null;
    try {
      final body = jsonDecode(text);
      if (body is! Map) return null;
      final failed = body['failed'];
      if (failed is! Map) return null;
      final role = '${failed['role'] ?? ''}';
      if (role.isEmpty || role == ctx.role) return null;
      return PartnerFailure(role, '${failed['message'] ?? ''}');
    } on FormatException {
      return null; // not JSON — nothing to learn from it
    }
  }

  Uri _uri(String path, Map<String, String> query) => Uri.parse(ctx.syncUrl)
      .replace(path: path, queryParameters: {'ns': _ns, ...query});

  Future<(int, String)> _send(String method, Uri uri, [Object? body]) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, uri);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, text);
    } finally {
      client.close();
    }
  }

  /// Blocks until [ctx.parties] parties (or [parties], if given) have arrived
  /// at the barrier [name].
  Future<void> barrier(
    String name, {
    int? parties,
    Duration? timeout,
    bool? failFast,
  }) async {
    final needed = parties ?? ctx.parties;
    final limit = timeout ?? const Duration(seconds: 120);
    await _send(
      'POST',
      _uri('/sync/arrive', {'name': name, 'party': ctx.role}),
    );
    final deadline = DateTime.now().add(limit);
    while (true) {
      final (status, text) = await _send(
        'GET',
        _uri('/sync/count', {'name': name}),
      );
      if (status == 200) {
        final count = (jsonDecode(text) as Map<String, dynamic>)['count'] as int;
        if (count >= needed) return;
      }
      final failure = _partnerFailure(text, failFast ?? this.failFast);
      if (failure != null) throw failure;
      if (DateTime.now().isAfter(deadline)) {
        throw SyncTimeout('barrier "$name": needed $needed parties '
            'within ${limit.inSeconds}s (role=${ctx.role})');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Emits event [name] with optional [data], visible to all parties.
  Future<void> emit(String name, [Map<String, Object?> data = const {}]) async {
    await _send('POST', _uri('/sync/emit', {'name': name}), data);
  }

  /// Blocks until event [name] has been emitted; returns its data.
  Future<Map<String, Object?>> waitForEvent(
    String name, {
    Duration? timeout,
    bool? failFast,
  }) async {
    final limit = timeout ?? const Duration(seconds: 120);
    final deadline = DateTime.now().add(limit);
    while (true) {
      final (status, text) = await _send(
        'GET',
        _uri('/sync/event', {'name': name}),
      );
      if (status == 200) {
        return (jsonDecode(text) as Map<String, dynamic>).cast<String, Object?>();
      }
      final failure = _partnerFailure(text, failFast ?? this.failFast);
      if (failure != null) throw failure;
      if (DateTime.now().isAfter(deadline)) {
        throw SyncTimeout('event "$name" not emitted '
            'within ${limit.inSeconds}s (role=${ctx.role})');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Asks the orchestrator to screenshot this role's device now, saved as
  /// `screenshots/NN_<label>.png` in the run's artifact tree. Call it at
  /// verification points. Never throws — a missing screenshot degrades the
  /// artifact bundle, it does not fail the test. Returns whether it worked.
  Future<bool> screenshot(String label) async {
    if (ctx.syncUrl.isEmpty) return false;
    try {
      final (status, _) = await _send(
        'POST',
        _uri('/artifact/screenshot', {'role': ctx.role, 'label': label}),
      ).timeout(const Duration(seconds: 40));
      return status == 200;
    } on Object {
      return false;
    }
  }

  /// Marks the start of a named step (module boundary). The orchestrator
  /// records the sequence with timestamps: per-step durations feed the
  /// performance audit (R15) and the step that was running when the test
  /// failed feeds failure clustering (R14). Never throws.
  Future<void> step(String name) async {
    if (ctx.syncUrl.isEmpty) return;
    try {
      await _send('POST', _uri('/harness/step', {'role': ctx.role, 'name': name}))
          .timeout(const Duration(seconds: 10));
    } on Object {
      // reporting only
    }
  }

  /// Reports the failure that is about to end this test (step + message).
  /// The first report in a test also releases every partner role waiting on
  /// a barrier/event/value, which throws [PartnerFailure] there. Never
  /// throws.
  Future<void> reportFailure(Object error) async {
    if (ctx.syncUrl.isEmpty) return;
    try {
      await _send(
        'POST',
        _uri('/harness/failure', {'role': ctx.role}),
        {'message': '$error'},
      ).timeout(const Duration(seconds: 10));
    } on Object {
      // reporting only
    }
  }

  /// Runs [body]; on failure reports the failure (R14), takes the failure
  /// screenshot (R13) and rethrows. Wrap every test body in it.
  ///
  /// This single wrapping catch is the *only* place a failure is published,
  /// which is what makes fail-fast cover a role that fails before it ever
  /// reaches a wait — there is no window in which the body has failed and
  /// partners have not been told. Reporting runs before the screenshot on
  /// purpose: the screenshot can take tens of seconds, and every partner
  /// spends that time still waiting.
  Future<T> guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (e) {
      await reportFailure(e);
      await screenshot('failure');
      rethrow;
    }
  }

  /// Harness service (R16): applies seed [profile] to THIS role's user now,
  /// through the orchestrator's seed loader and the backend's test-only seed
  /// endpoint. Declared preconditions in the manifest are applied before the
  /// body runs; call this only for mid-test seeding. Throws on failure.
  Future<void> seed(String profile) async {
    final (status, text) = await _send(
      'POST',
      _uri('/harness/seed', {'role': ctx.role, 'profile': profile}),
    ).timeout(const Duration(seconds: 90));
    if (status != 200) throw StateError('seed "$profile" failed: $text');
  }

  /// Harness service (R9b): account-level reset of THIS role's user — the
  /// backend wipes everything the user owns via its test-only endpoint.
  /// Throws on failure.
  Future<void> resetAccount() async {
    final (status, text) = await _send(
      'POST',
      _uri('/harness/reset-account', {'role': ctx.role}),
    ).timeout(const Duration(seconds: 90));
    if (status != 200) throw StateError('account reset failed: $text');
  }

  /// Stores [value] under [key] for other parties to read.
  Future<void> put(String key, Object? value) async {
    await _send('POST', _uri('/sync/kv', {'key': key}), {'value': value});
  }

  /// Reads the value under [key], waiting until it exists.
  Future<Object?> waitForValue(
    String key, {
    Duration? timeout,
    bool? failFast,
  }) async {
    final limit = timeout ?? const Duration(seconds: 120);
    final deadline = DateTime.now().add(limit);
    while (true) {
      final (status, text) = await _send('GET', _uri('/sync/kv', {'key': key}));
      if (status == 200) {
        return (jsonDecode(text) as Map<String, dynamic>)['value'];
      }
      final failure = _partnerFailure(text, failFast ?? this.failFast);
      if (failure != null) throw failure;
      if (DateTime.now().isAfter(deadline)) {
        throw SyncTimeout('kv "$key" not set within ${limit.inSeconds}s');
      }
      await Future<void>.delayed(pollInterval);
    }
  }
}
