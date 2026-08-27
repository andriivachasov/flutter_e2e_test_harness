// Deliberately flaky test (R14 fixture): fails on every odd run sequence
// number, always at the same step with the same message. `e2e audit` must
// cluster it as a consistent-step failure and suggest quarantine; tagged
// `quarantine` in the manifest, `e2e run` executes and reports it without
// letting it fail the run. It is a demonstration, not a product test.
import 'package:e2e_test_support/test_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'modules/sign_in.dart';

void main() {
  patrolTest('injected flake: fails on odd runs', ($) async {
    final ctx = TestContext.fromEnvironment();
    final sync = SyncClient(ctx);
    await sync.guard(() async {
      await sync.step('launch');
      await launchApp($);
      await sync.step('continue');
      await continueAs($, ctx);
      await sync.step('flaky-assertion');
      await sync.screenshot('before-assertion');
      expect(
        ctx.runSeq.isEven,
        isTrue,
        reason: 'injected flake: run seq ${ctx.runSeq} is odd',
      );
    });
  });
}
