// Auth module (R7): a plain function with typed input/output. Every
// feature test composes it; it never provisions users or seeds data — the
// orchestrator assigned a pool account before the body started (R8), and
// the APP registers that account on first use (D23).
import 'package:e2e_example_app/main.dart' as app;
import 'package:e2e_test_support/test_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import '../support/wait.dart';

/// Which path the app took: `registered` (account did not exist yet) or
/// `signed-in` (existing pool account).
class AuthResult {
  const AuthResult({required this.email, required this.mode});
  final String email;
  final String mode;
}

/// Pumps the app and waits for the auth page. Asserting the auth page (not
/// a restored session) is also the check that the harness's app-level
/// reset (R9a) happened: the previous test on this device left a session
/// behind, and it must be gone.
Future<void> launchApp(PatrolIntegrationTester $) async {
  await $.tester.pumpWidget(const app.E2EExampleApp());
  await waitVisible(
    $,
    find.byKey(const Key('auth_page')),
    timeout: const Duration(seconds: 30),
    because: 'app did not show the auth page (stale session on device?)',
  );
}

/// "Continue" as the role's pool account: the app signs in, or registers
/// the account first when it does not exist. Waits for the home page.
Future<AuthResult> continueAs(
  PatrolIntegrationTester $,
  TestContext ctx, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  if (!ctx.user.isProvisioned) {
    fail('no pool account for role ${ctx.role} '
        '(run through the orchestrator, not `patrol test` directly)');
  }
  await $.tester.enterText(find.byKey(const Key('email_field')), ctx.user.email);
  await $.tester.enterText(
    find.byKey(const Key('password_field')),
    ctx.user.password,
  );
  await $.tester.tap(find.byKey(const Key('continue_button')));
  await $.tester.pump();
  await waitVisible(
    $,
    find.byKey(const Key('signed_in_as')),
    timeout: timeout,
    because: 'continue did not reach the home page '
        '(error: ${_authError($)})',
  );
  final mode = find.byKey(const Key('auth_mode_registered')).evaluate().isNotEmpty
      ? 'registered'
      : 'signed-in';
  return AuthResult(email: ctx.user.email, mode: mode);
}

/// Signs out and waits for the auth page.
Future<void> signOut(PatrolIntegrationTester $) async {
  await $.tester.tap(find.byKey(const Key('sign_out_button')));
  await $.tester.pump();
  await waitVisible(
    $,
    find.byKey(const Key('auth_page')),
    timeout: const Duration(seconds: 15),
    because: 'sign-out did not return to the auth page',
  );
}

String _authError(PatrolIntegrationTester $) {
  final finder = find.byKey(const Key('sign_in_error'));
  if (finder.evaluate().isEmpty) return 'none shown';
  return (finder.evaluate().first.widget as Text).data ?? '?';
}
