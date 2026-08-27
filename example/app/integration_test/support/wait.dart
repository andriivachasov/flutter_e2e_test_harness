// Shared wait helper for the example's tests (module convention, R7:
// plain functions, typed inputs, no globals).
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

/// Polls for [finder] while pumping frames. Live-mode-safe replacement for
/// pumpAndSettle-based waiting: the app keeps polling its backend on a
/// timer, so we pump on an interval instead of waiting for frame quiet.
Future<void> waitVisible(
  PatrolIntegrationTester $,
  Finder finder, {
  required Duration timeout,
  String? because,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await $.tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('not visible within ${timeout.inSeconds}s: $finder'
          '${because == null ? '' : ' ($because)'}');
    }
  }
}
