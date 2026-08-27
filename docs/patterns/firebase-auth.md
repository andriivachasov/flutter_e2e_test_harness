# Firebase Auth in e2e

The harness assigns every test role a **pool account** — email
`<scope>-<role>@<email_domain>` and one shared password — and never talks
to Firebase Auth itself (D23). In `firebase.mode: emulator` (default) the
per-run Auth emulator starts empty, so the app registers every account
through its own sign-up flow; in `real` mode (dedicated test-only project,
D6) accounts persist and the app signs in. The test gets `ctx.user.email`
/ `.password` / `.scope`; the app must implement "register or continue"
against `E2E_AUTH_URL` (Identity Toolkit v1 base, resolved for the device)
with the Web API key `E2E_FIREBASE_API_KEY`.

## Variant A — REST (used by the reference app)

No native SDK config files, one code path for emulator and real:

```dart
Future<Session> continueWith(String email, String password) async {
  try {
    return await _call('accounts:signInWithPassword', email, password);   // existing account
  } on AuthException catch (e) {
    if (e.code == 'EMAIL_NOT_FOUND' || e.code == 'INVALID_LOGIN_CREDENTIALS') {
      return await _call('accounts:signUp', email, password);              // register + sign in
    }
    rethrow;
  }
}
// _call POSTs {'email','password','returnSecureToken':true} to
// '$kAuthUrl/$method?key=$kFirebaseApiKey' and returns idToken/localId/email.
```

Send `Authorization: Bearer <idToken>` to your backend; it verifies via
`accounts:lookup` (or the Admin SDK in production).

## Variant B — `firebase_auth` SDK

Keep the SDK; point it at the emulator in e2e builds:

```dart
const authUrl = String.fromEnvironment('E2E_AUTH_URL', defaultValue: '');
await Firebase.initializeApp(options: /* your FirebaseOptions; projectId may be the demo- id in e2e */);
if (authUrl.isNotEmpty && authUrl.startsWith('http://')) {
  final u = Uri.parse(authUrl);            // http://10.0.2.2:PORT/identitytoolkit.googleapis.com/v1
  await FirebaseAuth.instance.useAuthEmulator(u.host, u.port);
}
try {
  await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
} on FirebaseAuthException catch (e) {
  if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
    await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email, password: password);
  } else {
    rethrow;
  }
}
```

Pitfalls: `FirebaseOptions.apiKey/appId` must be syntactically valid even
for the emulator (`'1:123456789:ios:abcdef'` works); on iOS the SDK needs
`GoogleService-Info.plist` *or* Dart-side options — keep the plist out of
git if it identifies a real project; the SDK adds several minutes to cold
iOS builds (pods).

## Social / phone providers

Out of scope for e2e: they require a browser or SMS hop that Patrol cannot
drive deterministically. Add an email/password path guarded by a build
flag (`E2E_TEST_ID.isNotEmpty`) for tests, or a custom-token sign-in minted
by your backend's test endpoint.

## Backend verification

Emulator tokens are unsigned; real ones are RS256-signed. Verifying via
`POST ${AUTH_BASE_URL}/accounts:lookup {"idToken"}` works for both and
needs no crypto — cache per token. Production keeps its Admin SDK path.
