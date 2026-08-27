// D23 "register or continue": the first Continue with a pool account that
// does not exist yet registers it (regular sign-up flow); after sign-out,
// the second Continue signs the existing account in. Both paths are
// asserted through the app's own auth-mode banner.
//
// The account is per test (`returning_user-a@…`), so on a fresh emulator
// the first path is always "registered"; on a real project it may already
// exist from an earlier run — then both are "signed-in", which is fine and
// asserted as such.
import 'package:e2e_test_support/test_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'modules/sign_in.dart';

void main() {
  patrolTest('registers on first continue, signs in on the second', ($) async {
    final ctx = TestContext.fromEnvironment();
    final sync = SyncClient(ctx);
    await sync.guard(() async {
      await sync.step('launch');
      await launchApp($);
      await sync.step('first-continue');
      final first = await continueAs($, ctx);
      await sync.screenshot('first-continue-${first.mode}');
      expect(first.mode, anyOf('registered', 'signed-in'));

      await sync.step('sign-out');
      await signOut($);
      await sync.screenshot('signed-out');

      await sync.step('second-continue');
      final second = await continueAs($, ctx);
      expect(second.mode, 'signed-in',
          reason: 'the account existed after the first continue');
      await sync.screenshot('second-continue');
    });
  });
}
