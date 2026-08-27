import 'dart:io';

import 'package:e2e_orchestrator/src/config.dart';
import 'package:test/test.dart';

/// `backend.port_flag` (issue #4): the port argument(s) appended to
/// `backend.command` are a template, so a Spring Boot / Rails / Django
/// backend needs no wrapper script just to translate one flag.
void main() {
  HarnessConfig load(String backendYaml) {
    final dir = Directory.systemTemp.createTempSync('e2e_portflag');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/e2e.yaml')..writeAsStringSync(backendYaml);
    return HarnessConfig.load(f.path, env: {});
  }

  test('default is byte-identical to the old hardcoded --port <n>', () {
    final c = load('run:\n');
    expect(c.backendPortFlag, ['--port', '{port}']);
    expect(c.backendPortArgs(8099), ['--port', '8099']);
  });

  test('a string template becomes a single argument (Spring Boot)', () {
    final c = load('backend:\n  port_flag: "--server.port={port}"\n');
    expect(c.backendPortFlag, ['--server.port={port}']);
    expect(c.backendPortArgs(8123), ['--server.port=8123']);
  });

  test('a bare positional string works (Django-style host:port)', () {
    final c = load('backend:\n  port_flag: "127.0.0.1:{port}"\n');
    expect(c.backendPortArgs(9000), ['127.0.0.1:9000']);
  });

  test('a list template keeps its arguments separate (Rails)', () {
    final c = load('backend:\n  port_flag: ["-p", "{port}"]\n');
    expect(c.backendPortFlag, ['-p', '{port}']);
    expect(c.backendPortArgs(4000), ['-p', '4000']);
  });

  test('every {port} occurrence is substituted', () {
    final c = load(
      'backend:\n'
      '  port_flag: ["--port={port}", "--admin=127.0.0.1:{port}/{port}"]\n',
    );
    expect(c.backendPortArgs(7000), [
      '--port=7000',
      '--admin=127.0.0.1:7000/7000',
    ]);
  });

  test('a template without {port} is a config error', () {
    expect(
      () => load('backend:\n  port_flag: "--server.port=8080"\n'),
      throwsA(
        isA<ConfigError>().having(
          (e) => e.message,
          'message',
          allOf(contains('backend.port_flag'), contains('{port}')),
        ),
      ),
    );
    expect(
      () => load('backend:\n  port_flag: ["--port", "8080"]\n'),
      throwsA(isA<ConfigError>()),
    );
    expect(
      () => load('backend:\n  port_flag: []\n'),
      throwsA(isA<ConfigError>()),
    );
  });

  test('a non-string, non-list template is a config error', () {
    expect(
      () => load('backend:\n  port_flag: 8080\n'),
      throwsA(isA<ConfigError>()),
    );
  });
}
