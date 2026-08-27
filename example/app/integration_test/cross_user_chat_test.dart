// Two-user interaction test (R17/R18/R21): A (iOS) and B (Android) each
// sign in as their own provisioned user, exchange emails through the sync
// server's kv store, open a chat with each other and trade messages.
//
// Conventions this test demonstrates:
//  - context + sync via e2e_test_support (never sleep()-based coordination)
//  - sync.screenshot('<label>') at verification points and on failure
//  - modules (signIn, openChat, sendMessage, waitForMessage) do the steps
//  - both roles run this same file; the role decides the branch
import 'package:e2e_test_support/test_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'modules/chat.dart';
import 'modules/sign_in.dart';

void main() {
  patrolTest('messages are delivered between two users', ($) async {
    final ctx = TestContext.fromEnvironment();
    final sync = SyncClient(ctx);
    await sync.guard(() => _body($, ctx, sync));
  });
}

Future<void> _body(
  PatrolIntegrationTester $,
  TestContext ctx,
  SyncClient sync,
) async {
  await sync.step('launch');
  await launchApp($);
  await sync.step('continue');
  final me = await continueAs($, ctx);
  await sync.screenshot('signed-in');
  await sync.step('rendezvous');

  // Cross-device handoff: each role publishes its identity, reads the
  // other's. Roles are A and B; the partner is whichever we are not.
  await sync.put('email/${ctx.role}', me.email);
  final partnerRole = ctx.role == 'A' ? 'B' : 'A';
  final partner = await sync.waitForValue(
    'email/$partnerRole',
    timeout: const Duration(minutes: 10), // absorbs build/boot skew
  ) as String;

  // Cold caches build one platform much slower than the other; this
  // barrier absorbs the skew. Do not shorten it.
  await sync.barrier('app-ready', timeout: const Duration(minutes: 10));

  await sync.step('open-chat');
  await openChat($, partner);
  await sync.screenshot('chat-open');
  await sync.step('exchange');

  if (ctx.role == 'A') {
    await sendMessage($, 'hello from A');
    await sync.screenshot('sent');
    await sync.emit('a-sent');
    await waitForMessage($, 'hi from B', because: "A never saw B's reply");
    await sync.screenshot('reply-received');
  } else {
    await sync.waitForEvent('a-sent', timeout: const Duration(minutes: 2));
    await waitForMessage($, 'hello from A', because: "B never saw A's message");
    await sync.screenshot('received');
    await sendMessage($, 'hi from B');
    await sync.screenshot('replied');
  }

  // Both sides finish before either process exits, so neither device's
  // app is torn down while the other still asserts against the backend.
  await sync.step('done-barrier');
  await sync.barrier('done', timeout: const Duration(minutes: 2));
}
