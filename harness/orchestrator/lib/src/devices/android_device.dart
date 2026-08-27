import 'dart:async';
import 'dart:io';

import '../util/android_sdk.dart';
import '../util/proc.dart';
import 'device.dart';

class AndroidDeviceManager implements DeviceManager {
  AndroidDeviceManager({
    required this.avdName,
    required this.package,
    this.gpu = 'host',
  });

  final String avdName;

  /// `emulator -gpu <mode>`; empty leaves the choice to the emulator.
  final String gpu;

  /// Application id of the app under test (for launch detection).
  final String package;

  @override
  Future<bool> isAppRunning(DeviceHandle device) async {
    final r = await runProc(
      ['adb', '-s', device.id, 'shell', 'pidof', package],
      timeout: const Duration(seconds: 10),
    );
    return r.ok && r.stdout.trim().isNotEmpty;
  }

  @override
  DevicePlatform get platform => DevicePlatform.android;

  @override
  Future<void> clearAppData(DeviceHandle device) async {
    // `pm clear` wipes data + cache in place; "Failed" means not installed.
    await runProc(
      ['adb', '-s', device.id, 'shell', 'pm', 'clear', package],
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  Future<DeviceHandle> ensureReady() async {
    final existing = await _runningEmulatorSerial();
    final String serial;
    if (existing != null) {
      serial = existing;
    } else {
      // Start the emulator detached; it keeps running after the orchestrator
      // exits, which makes subsequent runs fast.
      await Process.start(
        emulatorBinary(),
        [
          '-avd', avdName,
          if (gpu.isNotEmpty) ...['-gpu', gpu],
          '-netdelay', 'none', '-netspeed', 'full',
        ],
        mode: ProcessStartMode.detached,
      );
      serial = await _waitFor<String>(
        _runningEmulatorSerial,
        timeout: const Duration(minutes: 3),
        what: 'emulator "$avdName" to appear in `adb devices`',
      );
    }

    await _waitFor(
      () async {
        final r = await runProc(
          ['adb', '-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
          timeout: const Duration(seconds: 10),
        );
        return r.stdout.trim() == '1' ? true : null;
      },
      timeout: const Duration(minutes: 4),
      what: 'Android emulator boot (sys.boot_completed)',
    );

    return DeviceHandle(
      platform: DevicePlatform.android,
      id: serial,
      name: avdName,
      // Android emulators reach the host loopback via 10.0.2.2.
      loopbackHost: '10.0.2.2',
    );
  }

  Future<String?> _runningEmulatorSerial() async {
    final r = await runProc(['adb', 'devices'], timeout: const Duration(seconds: 15));
    for (final line in r.stdout.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length == 2 && parts[0].startsWith('emulator-') && parts[1] == 'device') {
        // Only reuse an emulator that is actually running our AVD; the
        // developer may have an unrelated emulator open.
        final name = await runProc(
          ['adb', '-s', parts[0], 'emu', 'avd', 'name'],
          timeout: const Duration(seconds: 10),
        );
        if (name.ok && name.stdout.split('\n').first.trim() == avdName) {
          return parts[0];
        }
      }
    }
    return null;
  }

  Future<T> _waitFor<T>(
    Future<T?> Function() probe, {
    required Duration timeout,
    required String what,
    Duration interval = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final value = await probe();
      if (value != null) return value;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('timed out waiting for $what', timeout);
      }
      await Future<void>.delayed(interval);
    }
  }

  @override
  Future<void> screenshot(DeviceHandle device, File out) async {
    out.parent.createSync(recursive: true);
    // Capture on-device then pull: two bounded calls (R6) and no binary
    // stdout to babysit. Unique remote name so concurrent tests don't clash.
    // One bounded retry: screencap occasionally fails transiently on the
    // software-GPU emulator when the app is mid-repaint.
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      final remote =
          '/sdcard/e2e_shot_${DateTime.now().microsecondsSinceEpoch}.png';
      try {
        await runProcChecked(
          ['adb', '-s', device.id, 'shell', 'screencap', '-p', remote],
          context: 'Android screencap',
          timeout: const Duration(seconds: 30),
        );
        await runProcChecked(
          ['adb', '-s', device.id, 'pull', remote, out.path],
          context: 'pulling Android screenshot',
          timeout: const Duration(seconds: 30),
        );
        return;
      } on Object catch (e) {
        lastError = e;
      } finally {
        await runProc(
          ['adb', '-s', device.id, 'shell', 'rm', '-f', remote],
          timeout: const Duration(seconds: 15),
        );
      }
    }
    throw StateError('Android screenshot failed after retry: $lastError');
  }

  @override
  Future<VideoRecording> startVideo(DeviceHandle device, File out) async {
    out.parent.createSync(recursive: true);
    final remote = '/sdcard/e2e_recording.mp4';
    final process = await Process.start('adb', [
      '-s', device.id, 'shell', //
      'screenrecord', '--time-limit', '180', remote,
    ]);
    return _AndroidRecording(device.id, remote, out, process);
  }

  @override
  Future<LogCapture> startLogs(DeviceHandle device, File out) async {
    await runProc(
      ['adb', '-s', device.id, 'logcat', '-c'],
      timeout: const Duration(seconds: 15),
    );
    final proc = await ManagedProcess.start(
      'logcat-${device.id}',
      ['adb', '-s', device.id, 'logcat', '-v', 'time'],
      logFile: out,
    );
    return _AndroidLogCapture(proc);
  }
}

class _AndroidRecording implements VideoRecording {
  _AndroidRecording(this.serial, this.remotePath, this.out, this._process);
  final String serial;
  final String remotePath;
  final File out;
  final Process _process;

  @override
  Future<void> stop() async {
    // SIGINT lets screenrecord finalize the mp4 moov atom; a hard kill
    // corrupts it. Interrupt on-device, then reap our adb client.
    await runProc(
      ['adb', '-s', serial, 'shell', 'pkill', '-INT', 'screenrecord'],
      timeout: const Duration(seconds: 10),
    );
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
    // Give the device a beat to flush, then pull.
    await Future<void>.delayed(const Duration(seconds: 1));
    await runProcChecked(
      ['adb', '-s', serial, 'pull', remotePath, out.path],
      context: 'pulling Android recording',
      timeout: const Duration(minutes: 2),
    );
    await runProc(
      ['adb', '-s', serial, 'shell', 'rm', '-f', remotePath],
      timeout: const Duration(seconds: 15),
    );
  }
}

class _AndroidLogCapture implements LogCapture {
  _AndroidLogCapture(this._proc);
  final ManagedProcess _proc;

  @override
  Future<void> stop() => _proc.stop(signal: ProcessSignal.sigint);

  @override
  Future<int> get exited => _proc.exitCode;
}
