import 'dart:io';

/// Allocates free TCP ports without collisions within one orchestrator
/// process. Central allocator per plan §4 — nothing else picks ports.
class PortAllocator {
  final Set<int> _taken = {};

  /// Binds port 0 to let the OS pick a free port, reserves it, and returns it.
  Future<int> next() async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      if (_taken.add(port)) return port;
    }
    throw StateError('could not allocate a free port after 10 attempts');
  }
}
