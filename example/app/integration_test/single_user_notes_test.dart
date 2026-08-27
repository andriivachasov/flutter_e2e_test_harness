// Single-user feature test (R21) composing the sign-in module (R7): a fresh
// user has no notes, adds two, sees both persisted through the backend.
import 'package:e2e_test_support/test_support.dart';
import 'package:patrol/patrol.dart';

import 'modules/notes.dart';
import 'modules/sign_in.dart';

void main() {
  patrolTest('fresh user creates notes', ($) async {
    final ctx = TestContext.fromEnvironment();
    final sync = SyncClient(ctx);
    await sync.guard(() async {
      await sync.step('launch');
      await launchApp($);
      await sync.step('continue');
      await continueAs($, ctx);
      await sync.step('notes');
      await expectNoNotes($);
      await sync.screenshot('no-notes');

      await addNote($, 'Buy milk');
      await addNote($, 'Call the dentist');
      await expectNotes($, ['Buy milk', 'Call the dentist']);
      await sync.screenshot('two-notes');
    });
  });
}
