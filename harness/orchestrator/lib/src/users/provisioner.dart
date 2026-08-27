/// R10 / D23: test users are a fixed, deterministic pool of email/password
/// accounts. The harness never talks to Firebase Auth for them: it derives
/// the email from a scope + role, hands the credentials to the test, and
/// the APP registers the account on first use (regular sign-up flow) or
/// signs in when it already exists. No admin credentials, no leases.
///
/// Isolation between concurrently sharded tests comes from the scope: by
/// default every test role has its own account (`<test>-<role>@…`); a
/// manifest `users: {role: label}` override lets tests of one feature
/// share accounts. Parallel runs against one real project share the pool
/// (documented: one run per project at a time).
class TestUser {
  const TestUser({
    required this.email,
    required this.password,
    required this.scope,
    required this.role,
  });

  final String email;

  /// The shared pool password; only ever travels to the test process as a
  /// dart-define and is redacted from every log and artifact.
  final String password;
  final String scope;
  final String role;

  /// Safe for summary.json / logs: no password.
  Map<String, Object?> toJson() => {'email': email, 'scope': scope};
}

/// What a test role needs (R8): its scope (test name or override) and role.
class UserSpec {
  const UserSpec({required this.scope, required this.role});
  final String scope;
  final String role;
}

String _slug(String s) =>
    s.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// The one and only provisioner.
class PoolProvisioner {
  PoolProvisioner({required this.emailDomain, required this.password});

  final String emailDomain;
  final String password;

  String emailFor(UserSpec spec) =>
      '${_slug(spec.scope)}-${_slug(spec.role)}@$emailDomain';

  TestUser acquire(UserSpec spec) => TestUser(
        email: emailFor(spec),
        password: password,
        scope: spec.scope,
        role: spec.role,
      );
}
