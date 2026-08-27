// Smoke (R21): the app starts cold, continues as the role's pool account
// (registering it on first use — Firebase Auth), reaches the home page.
// Runs on whichever device is free.
import 'package:e2e_test_support/test_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'modules/sign_in.dart';

void main() {
  patrolTest('continues as the pool account and reaches the home page', ($) async {
    final ctx = TestContext.fromEnvironment();
    final sync = SyncClient(ctx);
    // guard(): failure screenshot + failure report (R13/R14), then rethrow.
    // step(): module boundaries, timed by the orchestrator (R15).
    await sync.guard(() async {
      await sync.step('launch');
      await launchApp($);
      await sync.screenshot('auth-page');
      await sync.step('continue');
      final session = await continueAs($, ctx);
      await sync.step('verify-home');
      expect(find.text(session.email), findsOneWidget);
      expect(find.byKey(const Key('error_banner')), findsNothing,
          reason: 'backend unreachable from the app');
      await sync.screenshot('home');
    });
  });
}
