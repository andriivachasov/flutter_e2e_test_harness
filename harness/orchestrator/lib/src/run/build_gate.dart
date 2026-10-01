import 'dart:async';

/// Lets one `patrol test` build at a time in the app directory (issue #14).
///
/// Every `patrol test` runs Flutter's plugin and package resolution in the
/// one app directory, which rewrites generated build files (on iOS with
/// Swift Package Manager: `ios/Flutter/ephemeral/Packages/
/// FlutterGeneratedPluginSwiftPackage/Package.swift`). Two builds started
/// together — the roles of a multi-device test, or single-user tests sharded
/// across devices — can rewrite a file the other build is reading, and the
/// iOS build fails with "was modified during the build". A role therefore
/// holds the gate from the start of its `patrol test` until its app is
/// running on the device (the build is over) or the role ends, whichever
/// comes first. Test bodies still run concurrently; only builds queue.
class BuildGate {
  Future<void> _tail = Future.value();
  int _holders = 0;

  /// True while a build holds the gate or waits for it.
  bool get busy => _holders > 0;

  /// Waits until every earlier build released the gate, then returns the
  /// function that releases it. Calling the release more than once is fine.
  Future<void Function()> acquire() async {
    _holders++;
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _holders--;
      done.complete();
    };
  }
}
