# Seeding and resets

**Rules (R9, R16).**

1. Fixture data is declarative: `seeds/<profile>.json`, loaded through the
   backend's test-only seed endpoint. Never drive the UI to create it;
   never write to the datastore behind the backend's back.
2. Every test starts from a known state:
   - **app-level reset (R9a)**: the harness wipes the app's on-device data
     before every role (`executor.reset_app_data: true`; Android `pm
     clear`, iOS uninstall + fresh install).
   - **account-level reset (R9b)**: `sync.resetAccount()` → `POST
     /test/reset/user {email}`; the backend deletes everything the account
     owns. The harness does this automatically for every pool account a
     run uses, before and after each test (accounts persist across runs).
3. Preconditions are declared, not performed: the manifest's `seed:` map
   is applied before the body runs; modules assume it.

**Seed profile.** A JSON object in your backend's format:

```json
{"notes": ["Seeded note one", "Seeded note two"],
 "messages": [{"from": "friend@example.com", "to": "me", "text": "hi"}]}
```

The harness posts it as `{"email","profile","data"}`; the backend
interprets `data`. Document the format in `seeds/README.md`.

**Manifest.**

```yaml
- name: seeded_history
  target: integration_test/seeded_history_test.dart
  tags: [single-user, seeding]
  roles: {A: any}
  seed: {A: user-with-history}
```

**Test.**

```dart
await continueAs($, ctx);
await expectNotes($, ['Seeded note one', 'Seeded note two']);   // precondition held
await sync.resetAccount();
await expectNoNotes($);                                        // R9b visible in the UI
await sync.seed('user-with-history');                          // mid-test seeding
```

**Isolation.** Concurrently sharded tests share one backend; each has its
own pool account (`<test>-<role>@…`), and all data is keyed by the
account's email, so nothing leaks between them. Never partition by
anything a production client sends.
