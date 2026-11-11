// Phase 3a: the speed test follows a pushed stream instead of polling.
//
// The kernel posts `{"method":"speedTest","data":{...}}` every 200 ms. These
// tests pin the two decisions that make the switch safe: a push is not an
// action result (so it never completes a Completer), and a run is "finished"
// by its own phase/error rather than by a `running` flag the UI has to infer.

import 'dart:convert';

import 'package:flrone/core/action.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors ThroneKernel's classification of one message-port frame.
({bool isSpeedTest, Map<String, dynamic>? frame}) classify(Object? raw) {
  if (raw is! String) return (isSpeedTest: false, frame: null);
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return (isSpeedTest: false, frame: null);
  }
  if (decoded is! Map) return (isSpeedTest: false, frame: null);
  if (decoded['method'] != 'speedTest') {
    return (isSpeedTest: false, frame: null);
  }
  final data = decoded['data'];
  if (data is! Map) return (isSpeedTest: false, frame: null);
  return (isSpeedTest: true, frame: Map<String, dynamic>.from(data));
}

/// Mirrors _SpeedTestPageState._applyFrame's terminal decision.
bool isFinished(Map<String, dynamic> frame) {
  final phase = '${frame['phase'] ?? ''}';
  return phase == 'done' || '${frame['error'] ?? ''}'.isNotEmpty;
}

void main() {
  group('speedTest push frames', () {
    test('a push is recognised and its data unwrapped', () {
      final result = classify(
        jsonEncode({
          'method': 'speedTest',
          'data': {'phase': 'download', 'speed': 8.2e7, 'progress': 0.4},
        }),
      );

      expect(result.isSpeedTest, isTrue);
      expect(result.frame!['phase'], 'download');
      expect(result.frame!['speed'], 8.2e7);
    });

    test('a push is not an action result', () {
      // The whole point: pushes carry no id/code, so they must not complete a
      // pending invoke. ActionResult.decode is the gate.
      final raw = jsonEncode({
        'method': 'speedTest',
        'data': {'phase': 'latency'},
      });
      expect(ActionResult.decode(raw), isNull);
      expect(classify(raw).isSpeedTest, isTrue);
    });

    test('other events are not speed-test frames', () {
      expect(
        classify(jsonEncode({'method': 'log', 'data': {'message': 'x'}}))
            .isSpeedTest,
        isFalse,
      );
      expect(classify('not json').isSpeedTest, isFalse);
      expect(classify(null).isSpeedTest, isFalse);
    });

    test('a push whose data is not a map is ignored', () {
      expect(
        classify(jsonEncode({'method': 'speedTest', 'data': 'oops'})).isSpeedTest,
        isFalse,
      );
    });
  });

  group('run termination', () {
    test('phase done finishes the run', () {
      expect(isFinished({'phase': 'done'}), isTrue);
    });

    test('an error verdict finishes it, whatever the phase', () {
      expect(isFinished({'phase': 'download', 'error': 'blocked'}), isTrue);
      expect(isFinished({'phase': '', 'error': 'unavailable'}), isTrue);
    });

    test('an in-flight frame does not', () {
      expect(isFinished({'phase': 'connecting'}), isFalse);
      expect(isFinished({'phase': 'latency', 'progress': 0.2}), isFalse);
      expect(isFinished({'phase': 'upload'}), isFalse);
    });

    test('a cancelled run reports finished via its error code', () {
      // The screen must stop following, but must NOT record history for it.
      expect(isFinished({'phase': 'download', 'error': 'cancelled'}), isTrue);
    });
  });
}
