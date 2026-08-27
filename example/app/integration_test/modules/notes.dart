// Notes module (R7): the single-user feature's steps as reusable functions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import '../support/wait.dart';

Finder _noteText(String text) => find.descendant(
      of: find.byKey(const Key('notes_list')),
      matching: find.text(text),
    );

/// Types [text] into the note field, adds it, and waits until the backend
/// round-trip shows it in the list.
Future<void> addNote(
  PatrolIntegrationTester $,
  String text, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  await $.tester.enterText(find.byKey(const Key('note_field')), text);
  await $.tester.tap(find.byKey(const Key('add_note_button')));
  await $.tester.pump();
  await waitVisible(
    $,
    _noteText(text),
    timeout: timeout,
    because: 'note "$text" never came back from the backend',
  );
}

/// Waits until every one of [texts] is listed (order-insensitive).
Future<void> expectNotes(
  PatrolIntegrationTester $,
  List<String> texts, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  for (final t in texts) {
    await waitVisible(
      $,
      _noteText(t),
      timeout: timeout,
      because: 'expected note "$t" in the list',
    );
  }
}

/// Waits until the list is empty.
Future<void> expectNoNotes(
  PatrolIntegrationTester $, {
  Duration timeout = const Duration(seconds: 30),
}) =>
    waitVisible(
      $,
      find.byKey(const Key('notes_empty')),
      timeout: timeout,
      because: 'notes list did not become empty',
    );
