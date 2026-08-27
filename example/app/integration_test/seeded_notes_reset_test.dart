// Seeding + account-level reset test (R9b, R16, R21).
//
// Precondition (manifest `seed: {A: user-with-history}`): before this body
// runs, the orchestrator loaded example/seeds/user-with-history.json through
// the backend's test-only seed endpoint for this role's user. The UI was
// never driven to create that data.
//
// Then the test asks the harness for an account-level reset (server-side,
// through the test-only reset endpoint) and watches the data vanish, and
// finally re-seeds mid-test to show the same service is available on demand.
import 'package:e2e_test_support/test_support.dart';
import 'package:patrol/patrol.dart';

import 'modules/notes.dart';
import 'modules/sign_in.dart';

const seededNotes = ['Seeded note one', 'Seeded note two', 'Seeded note three'];

void main() {
  patrolTest('seeded history is visible and an account reset clears it',
      ($) async {
    final ctx = TestContext.fromEnvironment();
    final sync = SyncClient(ctx);
    await sync.guard(() async {
      await sync.step('launch');
      await launchApp($);
      await sync.step('continue');
      await continueAs($, ctx);
      await sync.step('verify-seeded');
      await expectNotes($, seededNotes);
      await sync.screenshot('seeded');

      await sync.step('account-reset');
      await sync.resetAccount();
      await expectNoNotes($);
      await sync.screenshot('after-reset');

      await sync.step('re-seed');
      await sync.seed('user-with-history');
      await expectNotes($, seededNotes);
      await sync.screenshot('re-seeded');
    });
  });
}
