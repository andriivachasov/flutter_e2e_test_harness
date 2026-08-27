import 'dart:async';
import 'dart:io';


// Mutex keeps two graphics grabs (a `screencap` and a `screenrecord` start)
// off the same device at once — concurrent grabs wedge the software-GPU
// Android emulator's adb link.
export '../util/mutex.dart' show Mutex;

enum DevicePlatform { ios, android }


/// A ready-to-use device.
class DeviceHandle {
  DeviceHandle({
    required this.platform,
    required this.id,
    required this.name,
    required this.loopbackHost,
  });

  final DevicePlatform platform;

  /// simulator UDID or adb serial — what `patrol test -d` accepts.
  final String id;
  final String name;

  /// How this device reaches the host machine's loopback.
  final String loopbackHost;

  @override
  String toString() => '${platform.name}:$name($id)';
}

/// An in-progress screen recording; [stop] finalizes the file.
abstract class VideoRecording {
  Future<void> stop();
}

/// An in-progress device log capture; [stop] flushes and closes the file.
abstract class LogCapture {
  Future<void> stop();

  /// Completes with the capture process's exit code — before [stop] only if
  /// the capture died on its own (e.g. the device connection dropped).
  Future<int> get exited;
}

/// Per-platform device operations. Implementations must never hang:
/// every underlying call is bounded (R6).
abstract class DeviceManager {
  DevicePlatform get platform;

  /// Boots (or reuses) a device and returns its handle.
  Future<DeviceHandle> ensureReady();

  Future<void> screenshot(DeviceHandle device, File out);

  /// Whether the app under test currently has a live process on [device].
  /// Used to start video once the app is launched rather than during the
  /// build/install phase.
  Future<bool> isAppRunning(DeviceHandle device);

  /// Starts video capture. Failures inside capture must degrade the
  /// artifact bundle, never fail the test run (risk register).
  Future<VideoRecording> startVideo(DeviceHandle device, File out);

  Future<LogCapture> startLogs(DeviceHandle device, File out);

  /// R9a app-level reset: removes the app's on-device data (and, where that
  /// is the only way, the app itself — the executor reinstalls it). Not an
  /// error when the app is not installed.
  Future<void> clearAppData(DeviceHandle device);
}
