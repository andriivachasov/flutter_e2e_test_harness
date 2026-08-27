import 'package:e2e_orchestrator/src/util/ports.dart';
import 'package:test/test.dart';

void main() {
  test('allocates distinct ports', () async {
    final allocator = PortAllocator();
    final a = await allocator.next();
    final b = await allocator.next();
    final c = await allocator.next();
    expect({a, b, c}, hasLength(3));
    for (final p in [a, b, c]) {
      expect(p, greaterThan(0));
      expect(p, lessThan(65536));
    }
  });
}
