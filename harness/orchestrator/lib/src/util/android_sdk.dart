import 'dart:io';

/// Resolves the Android `emulator` binary. It typically is NOT on PATH even
/// when `adb` is: the SDK ships it in `<sdk>/emulator/`, and running the one
/// in `<sdk>/tools/` or via a bare name breaks AVD discovery. Resolution
/// order: $ANDROID_HOME, $ANDROID_SDK_ROOT, the SDK root derived from `adb`
/// on PATH, then the default per-OS SDK location. Falls back to the bare
/// name so PATH still works as a last resort.
String emulatorBinary() {
  final candidates = <String>[
    for (final envVar in ['ANDROID_HOME', 'ANDROID_SDK_ROOT'])
      if (Platform.environment[envVar] case final sdk?)
        '$sdk/emulator/emulator',
    if (_sdkRootFromAdb() case final sdk?) '$sdk/emulator/emulator',
    if (Platform.environment['HOME'] case final home?)
      Platform.isMacOS
          ? '$home/Library/Android/sdk/emulator/emulator'
          : '$home/Android/Sdk/emulator/emulator',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return 'emulator';
}

/// `<sdk>/platform-tools/adb` -> `<sdk>`, when adb is on PATH.
String? _sdkRootFromAdb() {
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
    final adb = File('$dir/adb');
    if (adb.existsSync() && dir.endsWith('platform-tools')) {
      return Directory(dir).parent.path;
    }
  }
  return null;
}
