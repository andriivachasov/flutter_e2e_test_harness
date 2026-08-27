# Stable widget keys (R23)

Selectors are the #1 flake source in UI tests, regardless of framework.
Text changes with copy and locale; positions change with layout. Keys
don't.

**Convention.**

- Every widget a test taps, types into, or asserts on has
  `key: const Key('snake_case_name')`.
- Names describe the role, not the look: `sign_in_button`, not
  `blue_button`. Suffixes: `_field`, `_button`, `_list`, `_tab`, `_page`,
  `_banner`, `_error`.
- List items carry the entity id: `Key('note_${note.id}')`,
  `Key('message_${m.id}')`. Assert on content with
  `find.descendant(of: find.byKey(Key('notes_list')), matching: find.text('…'))`.
- Page roots get a key (`sign_in_page`, `home_page`) so "which screen am I
  on" is one finder.
- Error/empty states get keys (`error_banner`, `notes_empty`): tests
  assert their absence/presence, which is far more robust than asserting
  on a message string.

**Asserting content.** For a keyed container use
`find.descendant(of: find.byKey(..), matching: find.text(..))`; for a keyed
`Text` itself add `matchRoot: true` (descendant excludes the root) or assert
`find.text(..)` directly.

**Where keys go. On the `TextField`/`FilledButton`/`ListView`/`ListTile`
itself (Flutter's `enterText` finds the `EditableText` descendant). For
custom widgets, put the key on the outer widget the test interacts with.

**Semantics.** If the app has accessibility labels, keys still win for
tests; `Semantics(identifier: …)` is an acceptable alternative when a key
cannot be attached (e.g. platform views).

**Reference.** `example/app/lib/main.dart` keys every interactive widget;
`integration_test/modules/*.dart` shows the finders.
