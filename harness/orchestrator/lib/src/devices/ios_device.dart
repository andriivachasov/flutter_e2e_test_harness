import 'dart:convert';
import 'dart:io';

import '../util/proc.dart';
import 'device.dart';

class IosDeviceManager implements DeviceManager {
  IosDeviceManager({required this.deviceName, required this.bundleId});

  final String deviceName;

  /// Bundle id of the app under test (for launch detection).
  final String bundleId;

  @override
  Future<bool> isAppRunning(DeviceHandle device) async {
    // launchctl lists running apps as "UIKitApplication:<bundle>[<hex>]".
    final r = await runProc(
      ['xcrun', 'simctl', 'spawn', device.id, 'launchctl', 'list'],
      timeout: const Duration(seconds: 15),
    );
    return r.ok && r.stdout.contains('UIKitApplication:$bundleId[');
  }

  @override
  DevicePlatform get platform => DevicePlatform.ios;

  @override
  Future<void> clearAppData(DeviceHandle device) async {
    // simctl has no "clear data": uninstalling drops the data container;
    // the next `patrol test` installs the app fresh. Exit code is non-zero
    // when the app is not installed, which is fine.
    await runProc(
      ['xcrun', 'simctl', 'uninstall', device.id, bundleId],
      timeout: const Duration(seconds: 60),
    );
  }

  @override
  Future<DeviceHandle> ensureReady() async {
    final list = await runProcChecked(
      ['xcrun', 'simctl', 'list', 'devices', '--json'],
      context: 'listing iOS simulators',
    );
    final parsed = jsonDecode(list.stdout) as Map<String, dynamic>;
    final devicesByRuntime = parsed['devices'] as Map<String, dynamic>;

    String? udid;
    String? state;
    // Runtimes are keyed like "com.apple.CoreSimulator.SimRuntime.iOS-18-0";
    // iterate newest-last and keep the last match so we prefer new runtimes.
    for (final entry in devicesByRuntime.entries) {
      for (final d in (entry.value as List).cast<Map<String, dynamic>>()) {
        if (d['name'] == deviceName && (d['isAvailable'] as bool? ?? false)) {
          udid = d['udid'] as String;
          state = d['state'] as String;
        }
      }
    }
    if (udid == null) {
      throw StateError(
        'iOS simulator "$deviceName" not found. Available devices: '
        '`xcrun simctl list devices`. Set devices.ios.name in e2e.yaml.',
      );
    }

    if (state != 'Booted') {
      await runProcChecked(
        ['xcrun', 'simctl', 'boot', udid],
        context: 'booting iOS simulator',
        timeout: const Duration(minutes: 3),
      );
    }
    // Wait for boot to fully complete either way; -b returns fast if booted.
    await runProcChecked(
      ['xcrun', 'simctl', 'bootstatus', udid, '-b'],
      context: 'waiting for iOS simulator boot',
      timeout: const Duration(minutes: 5),
    );

    return DeviceHandle(
      platform: DevicePlatform.ios,
      id: udid,
      name: deviceName,
      loopbackHost: '127.0.0.1',
    );
  }

  @override
  Future<void> screenshot(DeviceHandle device, File out) async {
    out.parent.createSync(recursive: true);
    await runProcChecked(
      ['xcrun', 'simctl', 'io', device.id, 'screenshot', out.path],
      context: 'iOS screenshot',
    );
  }

  @override
  Future<VideoRecording> startVideo(DeviceHandle device, File out) async {
    out.parent.createSync(recursive: true);
    final process = await Process.start('xcrun', [
      'simctl',
      'io',
      device.id,
      'recordVideo',
      '--codec',
      'h264',
      '--force',
      out.path,
    ]);
    final output = StringBuffer();
    process.stdout.transform(utf8.decoder).forEach(output.write).ignore();
    process.stderr.transform(utf8.decoder).forEach(output.write).ignore();
    // recordVideo fails immediately (bad device, recorder busy) instead of
    // at SIGINT time; surface that as a start failure so the collector warns.
    final earlyExit = await process.exitCode
        .timeout(const Duration(seconds: 2), onTimeout: () => _stillRunning);
    if (earlyExit != _stillRunning) {
      throw StateError(
        'simctl recordVideo exited immediately (code $earlyExit): $output',
      );
    }
    return _IosRecording(process, out, output);
  }

  static const _stillRunning = -0xbeef;

  @override
  Future<LogCapture> startLogs(DeviceHandle device, File out) async {
    final proc = await ManagedProcess.start(
      'ios-log-${device.id}',
      [
        'xcrun', 'simctl', 'spawn', device.id, //
        'log', 'stream', '--style', 'compact',
        '--predicate', 'process == "Runner"',
      ],
      logFile: out,
    );
    return _ManagedCapture(proc);
  }
}

class _IosRecording implements VideoRecording {
  _IosRecording(this._process, this._out, this._output);
  final Process _process;
  final File _out;
  final StringBuffer _output;

  @override
  Future<void> stop() async {
    // simctl finalizes the file on SIGINT; h264 finalization of a long
    // recording can take a while. A SIGKILL here loses the file AND leaves
    // CoreSimulator's host recorder stuck until the simulator reboots, so
    // give finalization a generous bound before declaring it wedged.
    _process.kill(ProcessSignal.sigint);
    var killed = false;
    await _process.exitCode.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        killed = true;
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
    if (killed || !_out.existsSync() || _out.lengthSync() == 0) {
      throw StateError(
        'simctl recordVideo did not produce ${_out.path}'
        '${killed ? ' (killed after finalize timeout; simulator may need a '
            'reboot to record again)' : ''}: $_output',
      );
    }
  }
}

class _ManagedCapture implements LogCapture {
  _ManagedCapture(this._proc);
  final ManagedProcess _proc;

  @override
  Future<void> stop() => _proc.stop(signal: ProcessSignal.sigint);

  @override
  Future<int> get exited => _proc.exitCode;
}
