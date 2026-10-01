import 'dart:async';

import 'package:e2e_orchestrator/src/run/build_gate.dart';
import 'package:test/test.dart';

void main() {
  test('a second build waits until the first releases the gate', () async {
    final gate = BuildGate();
    final releaseFirst = await gate.acquire();
    var secondStarted = false;
    final second = gate.acquire().then((release) {
      secondStarted = true;
      return release;
    });

    await Future<void>.delayed(Duration.zero);
    expect(secondStarted, isFalse);
    expect(gate.busy, isTrue);

    releaseFirst();
    (await second)();
    expect(secondStarted, isTrue);
    expect(gate.busy, isFalse);
  });

  test('builds get the gate in the order they asked for it', () async {
    final gate = BuildGate();
    final order = <int>[];
    final releases = <Future<void Function()>>[
      for (var i = 0; i < 3; i++)
        gate.acquire().then((release) {
          order.add(i);
          return release;
        }),
    ];
    for (final r in releases) {
      (await r)();
    }
    expect(order, [0, 1, 2]);
  });

  test('releasing twice does not let two builds in at once', () async {
    final gate = BuildGate();
    final first = await gate.acquire();
    first();
    first();
    final second = await gate.acquire();
    var thirdStarted = false;
    unawaited(gate.acquire().then((_) => thirdStarted = true));
    await Future<void>.delayed(Duration.zero);
    expect(thirdStarted, isFalse);
    second();
  });
}
