import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of a bounded subprocess run.
class ProcResult {
  ProcResult({
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
    this.aborted = false,
  });

  final List<String> command;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  /// True when the caller's [abort] future fired and we killed the process.
  final bool aborted;

  bool get ok => exitCode == 0 && !timedOut && !aborted;

  String describe() => timedOut
      ? 'TIMEOUT: ${command.join(' ')}'
      : aborted
          ? 'ABORTED: ${command.join(' ')}'
          : 'exit $exitCode: ${command.join(' ')}';

  /// Last [lines] lines of combined output, for error messages.
  String tail([int lines = 20]) {
    final all = '$stdout\n$stderr'.trim().split('\n');
    return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
  }
}

class ProcError implements Exception {
  ProcError(this.result, [this.context]);
  final ProcResult result;
  final String? context;
  @override
  String toString() =>
      'ProcError${context == null ? '' : ' ($context)'}: ${result.describe()}\n'
      '${result.tail()}';
}

/// Runs [command] to completion with a hard [timeout]. R6: every external
/// call is bounded; a timeout kills the process and reports it.
///
/// If [abort] completes first, the process is terminated (SIGTERM, then
/// SIGKILL after a short grace period) and the result is marked aborted —
/// used to tear down test processes when the environment dies underneath
/// them (e.g. backend crash) instead of waiting for their own timeouts.
Future<ProcResult> runProc(
  List<String> command, {
  String? cwd,
  Map<String, String>? environment,
  Duration timeout = const Duration(minutes: 2),
  void Function(String line)? onLine,
  Future<void>? abort,
}) async {
  final process = await Process.start(
    command.first,
    command.sublist(1),
    workingDirectory: cwd,
    environment: environment,
  );
  final out = StringBuffer();
  final err = StringBuffer();
  final outDone = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach((l) {
    out.writeln(l);
    onLine?.call(l);
  });
  final errDone = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach((l) {
    err.writeln(l);
    onLine?.call(l);
  });

  var timedOut = false;
  var aborted = false;
  var exited = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    process.kill(ProcessSignal.sigkill);
  });
  Timer? abortKill;
  abort?.then((_) {
    if (exited) return;
    aborted = true;
    process.kill(ProcessSignal.sigterm);
    abortKill = Timer(const Duration(seconds: 10), () {
      if (!exited) process.kill(ProcessSignal.sigkill);
    });
  }).ignore();
  final code = await process.exitCode;
  exited = true;
  timer.cancel();
  abortKill?.cancel();
  await outDone;
  await errDone;
  return ProcResult(
    command: command,
    exitCode: code,
    stdout: out.toString(),
    stderr: err.toString(),
    timedOut: timedOut,
    aborted: aborted,
  );
}

/// Like [runProc] but throws on failure.
Future<ProcResult> runProcChecked(
  List<String> command, {
  String? cwd,
  Map<String, String>? environment,
  Duration timeout = const Duration(minutes: 2),
  String? context,
}) async {
  final result = await runProc(
    command,
    cwd: cwd,
    environment: environment,
    timeout: timeout,
  );
  if (!result.ok) throw ProcError(result, context);
  return result;
}

/// A long-running child process whose output streams into a log file.
class ManagedProcess {
  ManagedProcess._(this.name, this._process, this._sink, this._flushed);

  final String name;
  final Process _process;
  final IOSink _sink;
  final Future<void> _flushed;

  static Future<ManagedProcess> start(
    String name,
    List<String> command, {
    String? cwd,
    Map<String, String>? environment,
    required File logFile,
  }) async {
    logFile.parent.createSync(recursive: true);
    final sink = logFile.openWrite();
    final process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: cwd,
      environment: environment,
    );
    final outDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(sink.writeln);
    final errDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((l) => sink.writeln('[stderr] $l'));
    final flushed = Future.wait([outDone, errDone]);
    return ManagedProcess._(name, process, sink, flushed);
  }

  int get pid => _process.pid;

  Future<int> get exitCode => _process.exitCode;

  /// Stops the process: [signal] first, escalating to SIGKILL after
  /// [grace] if it has not exited.
  Future<void> stop({
    ProcessSignal signal = ProcessSignal.sigterm,
    Duration grace = const Duration(seconds: 5),
  }) async {
    _process.kill(signal);
    await _process.exitCode.timeout(grace, onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      return _process.exitCode;
    });
    await _flushed.catchError((Object _) => <void>[]);
    await _sink.flush();
    await _sink.close();
  }
}
