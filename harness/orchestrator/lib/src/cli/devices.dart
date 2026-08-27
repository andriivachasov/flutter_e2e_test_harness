import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../util/android_sdk.dart';
import '../util/proc.dart';

/// `e2e devices`: the configured device per platform and its current state.
/// Exit 0 when every configured device exists (booted or not), 1 otherwise.
Future<int> devices(HarnessConfig config) async {
  var missing = 0;

  if (Platform.isMacOS) {
    final r = await runProc(
      ['xcrun', 'simctl', 'list', 'devices', '--json'],
      timeout: const Duration(seconds: 30),
    );
    if (!r.ok) {
      stdout.writeln('ios      "${config.iosDeviceName}"  — simctl not '
          'runnable (${r.describe()})');
      missing++;
    } else {
      final parsed = jsonDecode(r.stdout) as Map<String, dynamic>;
      final byRuntime = parsed['devices'] as Map<String, dynamic>;
      String? state, udid, runtime;
      for (final entry in byRuntime.entries) {
        for (final d in (entry.value as List).cast<Map<String, dynamic>>()) {
          if (d['name'] == config.iosDeviceName &&
              (d['isAvailable'] as bool? ?? false)) {
            state = d['state'] as String?;
            udid = d['udid'] as String?;
            runtime = entry.key.split('.').last;
          }
        }
      }
      if (udid == null) {
        stdout.writeln('ios      "${config.iosDeviceName}"  — NOT FOUND '
            '(bash m1/step3_devices.sh creates it)');
        missing++;
      } else {
        stdout.writeln('ios      "${config.iosDeviceName}"  $udid  '
            '$runtime  ${state ?? '?'}');
      }
    }
  } else {
    stdout.writeln('ios      — not available on ${Platform.operatingSystem}');
  }

  final avds = await runProc(
    [emulatorBinary(), '-list-avds'],
    timeout: const Duration(seconds: 30),
  );
  if (!avds.ok) {
    stdout.writeln('android  "${config.androidAvd}"  — emulator not runnable '
        '(${avds.describe()})');
    missing++;
  } else {
    final exists =
        avds.stdout.split('\n').map((l) => l.trim()).contains(config.androidAvd);
    if (!exists) {
      stdout.writeln('android  "${config.androidAvd}"  — NOT FOUND '
          '(bash m1/step3_devices.sh creates it)');
      missing++;
    } else {
      var state = 'Shutdown';
      final adb = await runProc(['adb', 'devices'], timeout: const Duration(seconds: 15));
      if (adb.ok) {
        for (final line in adb.stdout.split('\n')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length == 2 && parts[0].startsWith('emulator-')) {
            final name = await runProc(
              ['adb', '-s', parts[0], 'emu', 'avd', 'name'],
              timeout: const Duration(seconds: 10),
            );
            if (name.ok &&
                name.stdout.split('\n').first.trim() == config.androidAvd) {
              state = 'Booted (${parts[0]})';
            }
          }
        }
      }
      stdout.writeln('android  "${config.androidAvd}"  $state');
    }
  }

  return missing == 0 ? 0 : 1;
}
