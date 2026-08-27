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

/// Client for the orchestrator's sync server (barriers, events, kv).
///
/// Transport is plain HTTP polling — no held connections, no dependencies.
/// Never use sleep()-based coordination in tests; use these primitives.
class SyncClient {
  SyncClient(this.ctx) : _ns = '${ctx.runId}/${ctx.testId}';

  final TestContext ctx;
  final String _ns;
  final Duration pollInterval = const Duration(milliseconds: 300);

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
  Future<void> barrier(String name, {int? parties, Duration? timeout}) async {
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
  /// Never throws.
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

  /// Runs [body]; on failure takes the failure screenshot (R13), reports
  /// the failure (R14) and rethrows. Wrap every test body in it.
  Future<T> guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (e) {
      await screenshot('failure');
      await reportFailure(e);
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
  Future<Object?> waitForValue(String key, {Duration? timeout}) async {
    final limit = timeout ?? const Duration(seconds: 120);
    final deadline = DateTime.now().add(limit);
    while (true) {
      final (status, text) = await _send('GET', _uri('/sync/kv', {'key': key}));
      if (status == 200) {
        return (jsonDecode(text) as Map<String, dynamic>)['value'];
      }
      if (DateTime.now().isAfter(deadline)) {
        throw SyncTimeout('kv "$key" not set within ${limit.inSeconds}s');
      }
      await Future<void>.delayed(pollInterval);
    }
  }
}
