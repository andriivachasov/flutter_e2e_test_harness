import 'package:e2e_orchestrator/src/users/provisioner.dart';
import 'package:test/test.dart';

void main() {
  final pool = PoolProvisioner(emailDomain: 'e2e.example.com', password: 'pw');

  test('emails are deterministic per scope and role', () {
    final a = pool.acquire(const UserSpec(scope: 'cross_user_chat', role: 'A'));
    expect(a.email, 'cross-user-chat-a@e2e.example.com');
    expect(a.password, 'pw');
    expect(a.scope, 'cross_user_chat');
    expect(pool.acquire(const UserSpec(scope: 'cross_user_chat', role: 'A')).email, a.email);
    expect(pool.acquire(const UserSpec(scope: 'cross_user_chat', role: 'B')).email,
        'cross-user-chat-b@e2e.example.com');
  });

  test('a feature label override shares accounts across tests', () {
    expect(pool.acquire(const UserSpec(scope: 'Chat Writer', role: 'A')).email,
        'chat-writer-a@e2e.example.com');
  });

  test('toJson never carries the password', () {
    final u = pool.acquire(const UserSpec(scope: 't', role: 'A'));
    expect(u.toJson().values, isNot(contains('pw')));
  });
}
