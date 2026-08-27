/// Per-test-process context, delivered by the orchestrator via --dart-define.
///
/// The same defines reach both the app under test and the test code (they run
/// in one process under integration_test/Patrol).
class TestContext {
  const TestContext({
    required this.runId,
    required this.testId,
    required this.role,
    required this.backendUrl,
    required this.syncUrl,
    required this.parties,
    required this.user,
    required this.authUrl,
    required this.apiKey,
    required this.runSeq,
  });

  /// Reads the context from --dart-define values.
  ///
  /// [String.fromEnvironment] must be called with const on mobile targets,
  /// hence the const defaults here.
  factory TestContext.fromEnvironment() {
    const runId = String.fromEnvironment('E2E_RUN_ID', defaultValue: 'dev');
    const testId = String.fromEnvironment('E2E_TEST_ID', defaultValue: 'dev');
    const role = String.fromEnvironment('E2E_ROLE', defaultValue: 'A');
    const backendUrl = String.fromEnvironment(
      'E2E_BACKEND_URL',
      defaultValue: 'http://127.0.0.1:8080',
    );
    const syncUrl = String.fromEnvironment('E2E_SYNC_URL', defaultValue: '');
    const parties = int.fromEnvironment('E2E_PARTIES', defaultValue: 1);
    const authUrl = String.fromEnvironment(
      'E2E_AUTH_URL',
      defaultValue: 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1',
    );
    const apiKey =
        String.fromEnvironment('E2E_FIREBASE_API_KEY', defaultValue: 'any');
    const runSeq = int.fromEnvironment('E2E_RUN_SEQ', defaultValue: 0);
    const user = TestUserCredentials(
      email: String.fromEnvironment('E2E_USER_EMAIL', defaultValue: ''),
      password: String.fromEnvironment('E2E_USER_PASSWORD', defaultValue: ''),
      scope: String.fromEnvironment('E2E_USER_SCOPE', defaultValue: ''),
    );
    return const TestContext(
      runId: runId,
      testId: testId,
      role: role,
      backendUrl: backendUrl,
      syncUrl: syncUrl,
      parties: parties,
      user: user,
      authUrl: authUrl,
      apiKey: apiKey,
      runSeq: runSeq,
    );
  }

  final String runId;
  final String testId;

  /// This process's role in a multi-user test, e.g. 'A' or 'B'.
  final String role;

  /// Backend base URL, already resolved for this device's loopback
  /// (10.0.2.2 on Android emulators, 127.0.0.1 on iOS simulators).
  final String backendUrl;

  /// Sync server base URL (empty when running a single-user test standalone).
  final String syncUrl;

  /// Number of participating devices in this test.
  final int parties;

  /// The pool account assigned to this role (R10, D23): deterministic
  /// email + shared pool password. The account may not exist yet — the app
  /// registers it on first use and signs in afterwards. Preconditions (seed
  /// profile) were applied to its email before the test body started (R8).
  final TestUserCredentials user;

  /// Identity Toolkit v1 base the app signs in against — the Auth emulator
  /// (via this device's loopback) or `https://identitytoolkit.googleapis.com/v1`.
  final String authUrl;

  /// Firebase Web API key: any value for the emulator, the project's key
  /// for a real project. A public client identifier, not a secret.
  final String apiKey;

  /// Monotonic run counter on this machine (`runs/.seq`); 0 outside the
  /// orchestrator. Lets a fixture behave deterministically across
  /// consecutive runs (the injected flaky test fails on odd runs).
  final int runSeq;
}

/// Credentials of the role's pool account. Only ever present in the test
/// process; the password is redacted from every harness log.
class TestUserCredentials {
  const TestUserCredentials({
    required this.email,
    required this.password,
    required this.scope,
  });

  /// `<scope>-<role>@<email_domain>`.
  final String email;
  final String password;

  /// The pool scope the account belongs to: the test name by default, or
  /// the manifest's `users: {role: label}` override.
  final String scope;

  bool get isProvisioned => email.isNotEmpty;
}
