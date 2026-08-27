# ADR-011 (D11): App-side Firebase sign-in (2026-08-26, M3)

**Status:** accepted · 2026-08-26

## Decision

**The example app signs in through the Firebase Auth REST API (Identity Toolkit `accounts:signInWithPassword`), not the native `firebase_auth` SDK.** The base URL (`E2E_AUTH_URL`) and Web API key (`E2E_FIREBASE_API_KEY`) arrive as dart-defines, so one code path serves the emulator and a real project

## Rationale

No per-platform Firebase config files (`GoogleService-Info.plist`, `google-services.json`), no Firebase pods/gradle plugins in the build, and nothing to keep out of git. The playbook documents the SDK variant (`FirebaseAuth.instance.useAuthEmulator(host, port)` + `FirebaseOptions` from defines) for apps that already use it.

## Where it lives

See `refined_requirements.md` (D11) and the playbook steps that apply it.
