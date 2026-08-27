// Chat module (R7): the two-user interaction's steps. Delivery in the
// example is polling (D8); `waitForMessage` is the wait-for-cross-user-state
// pattern the playbook documents for websockets/SSE/push as well.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import '../support/wait.dart';

/// Opens the conversation with [partnerEmail].
Future<void> openChat(PatrolIntegrationTester $, String partnerEmail) async {
  await $.tester.tap(find.byKey(const Key('chat_tab')));
  await $.tester.pump();
  await waitVisible(
    $,
    find.byKey(const Key('partner_field')),
    timeout: const Duration(seconds: 15),
    because: 'chat tab did not open',
  );
  await $.tester.enterText(find.byKey(const Key('partner_field')), partnerEmail);
  await $.tester.tap(find.byKey(const Key('open_chat_button')));
  await $.tester.pump();
  await waitVisible(
    $,
    find.byKey(const Key('message_list')),
    timeout: const Duration(seconds: 15),
    because: 'conversation did not open',
  );
}

/// Sends [text] in the open conversation and waits for it to echo back.
Future<void> sendMessage(PatrolIntegrationTester $, String text) async {
  await $.tester.enterText(find.byKey(const Key('message_field')), text);
  await $.tester.tap(find.byKey(const Key('send_message_button')));
  await $.tester.pump();
  await waitForMessage($, text, because: 'own message never echoed back');
}

/// Waits until a message with [text] is visible in the open conversation.
Future<void> waitForMessage(
  PatrolIntegrationTester $,
  String text, {
  Duration timeout = const Duration(seconds: 60),
  String? because,
}) =>
    waitVisible(
      $,
      find.descendant(
        of: find.byKey(const Key('message_list')),
        matching: find.text(text),
      ),
      timeout: timeout,
      because: because ?? 'message "$text" did not arrive',
    );
