import 'dart:async';
import 'dart:io';

import '../devices/device.dart';

/// Per-device capture handles for one test.
class DeviceCapture {
  DeviceCapture({
    required this.device,
    required this.manager,
    required this.dir,
  });

  final DeviceHandle device;
  final DeviceManager manager;
  final Directory dir;

  /// Resolves once video capture has started (or failed / was cancelled).
  /// Recording is deferred until the app is actually running on the device
  /// so the video doesn't spend minutes on the build/install phase.
  Future<VideoRecording?> video = Future.value(null);
  LogCapture? logs;

  /// Set when the test is over: stops waiting for the app to launch.
  bool ended = false;

  /// When the app under test was first seen running on the device — the
  /// end of the build+install phase (R15). Null if it never launched.
  DateTime? appLaunchedAt;

  /// Next screenshot sequence number; 00 = start, 99 = end.
  int screenshotSeq = 1;

  /// Serializes graphics grabs (screencap / video start) on this device.
  final Mutex graphicsLock = Mutex();
}

/// Owns the runs/<run>/<test>/ artifact tree (R12). Capture failures are
/// logged as warnings and degrade the bundle — they never fail the test.
class ArtifactCollector {
  ArtifactCollector({
    required this.runDir,
    required this.warn,
    required this.appLaunchTimeout,
    this.captureVideo = true,
    this.appLaunchPollInterval = const Duration(seconds: 1),
  });

  final Directory runDir;
  final void Function(String message) warn;

  /// Upper bound on waiting for the app to appear on a device before video
  /// capture is abandoned (normally the per-role test timeout).
  final Duration appLaunchTimeout;

  /// When false, no screen recording is started (run.capture_video).
  final bool captureVideo;
  final Duration appLaunchPollInterval;

  Directory testDir(String testName) =>
      Directory('${runDir.path}/$testName')..createSync(recursive: true);

  Directory deviceDir(String testName, String role) =>
      Directory('${runDir.path}/$testName/$role')..createSync(recursive: true);

  /// Starts log capture and the start screenshot for [device] playing
  /// [role] in [testName]; video starts as soon as the app launches.
  Future<DeviceCapture> beginDevice(
    String testName,
    String role,
    DeviceHandle device,
    DeviceManager manager,
  ) async {
    final dir = deviceDir(testName, role);
    final capture = DeviceCapture(device: device, manager: manager, dir: dir);
    try {
      final logs = await manager.startLogs(
        device,
        File('${dir.path}/app.log'),
      );
      capture.logs = logs;
      logs.exited.then((code) {
        if (!capture.ended) {
          warn('app log capture for $device ended early (exit $code) — '
              'device connection lost? app.log is truncated');
        }
      }).ignore();
    } on Object catch (e) {
      warn('log capture failed to start for $device: $e');
    }
    try {
      await capture.graphicsLock.run(() => manager.screenshot(
            device,
            File('${dir.path}/screenshots/00_start.png'),
          ));
    } on Object catch (e) {
      warn('start screenshot failed for $device: $e');
    }
    // Always watch for the launch (R15 timing); record only if enabled.
    capture.video = _startVideoOnLaunch(capture);
    return capture;
  }

  /// Polls (bounded) until the app under test is running, then starts the
  /// recording. Returns null if the test ended first or capture failed.
  Future<VideoRecording?> _startVideoOnLaunch(DeviceCapture capture) async {
    final deadline = DateTime.now().add(appLaunchTimeout);
    try {
      while (!capture.ended) {
        if (await capture.manager.isAppRunning(capture.device)) {
          capture.appLaunchedAt ??= DateTime.now();
          if (!captureVideo) return null;
          return await capture.graphicsLock.run(() => capture.manager.startVideo(
                capture.device,
                File('${capture.dir.path}/video.mp4'),
              ));
        }
        if (DateTime.now().isAfter(deadline)) {
          warn('video not started for ${capture.device}: app did not launch '
              'within ${appLaunchTimeout.inSeconds}s');
          return null;
        }
        await Future<void>.delayed(appLaunchPollInterval);
      }
      warn('video not started for ${capture.device}: test ended before the '
          'app launched');
    } on Object catch (e) {
      warn('video capture failed to start for ${capture.device}: $e');
    }
    return null;
  }

  /// Screenshot requested by the test itself (via the sync server) at a
  /// verification point. Files are numbered in request order.
  Future<File> screenshot(DeviceCapture capture, String label) async {
    final safe = label
        .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final seq = capture.screenshotSeq++;
    final out = File(
      '${capture.dir.path}/screenshots/'
      '${seq.toString().padLeft(2, '0')}_${safe.isEmpty ? 'shot' : safe}.png',
    );
    await capture.graphicsLock.run(() => capture.manager.screenshot(
          capture.device,
          out,
        ));
    return out;
  }

  /// Stops captures and takes the final screenshot.
  Future<void> endDevice(DeviceCapture capture) async {
    capture.ended = true;
    final manager = capture.manager;
    try {
      await capture.graphicsLock.run(() => manager.screenshot(
            capture.device,
            File('${capture.dir.path}/screenshots/99_end.png'),
          ));
    } on Object catch (e) {
      warn('end screenshot failed for ${capture.device}: $e');
    }
    try {
      // Bounded: the launch poll itself is bounded by appLaunchTimeout and
      // exits promptly once `ended` is set.
      final video = await capture.video;
      await video?.stop();
    } on Object catch (e) {
      warn('video finalize failed for ${capture.device}: $e');
    }
    try {
      await capture.logs?.stop();
    } on Object catch (e) {
      warn('log capture stop failed for ${capture.device}: $e');
    }
  }
}
