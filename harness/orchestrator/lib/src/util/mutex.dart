import 'dart:async';

/// Serializes async operations: [run] calls execute one at a time, in order.
class Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}
