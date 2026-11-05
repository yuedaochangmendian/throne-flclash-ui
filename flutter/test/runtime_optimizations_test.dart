import 'dart:io';

import 'package:b_box_ui/common/config_guard.dart';
import 'package:b_box_ui/common/isolate_json.dart';
import 'package:b_box_ui/common/refresh_gate.dart';
import 'package:b_box_ui/common/throttle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Debouncer', () {
    test('coalesces a burst per tag', () async {
      final debouncer = Debouncer();
      var a = 0;
      var b = 0;
      for (var i = 0; i < 5; i++) {
        debouncer.run('a', () => a++, duration: const Duration(milliseconds: 10));
      }
      debouncer.run('b', () => b++, duration: const Duration(milliseconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(a, 1);
      expect(b, 1);
      debouncer.cancelAll();
    });

    test('cancel drops a pending call', () async {
      final debouncer = Debouncer();
      var calls = 0;
      debouncer.run('a', () => calls++, duration: const Duration(milliseconds: 10));
      debouncer.cancel('a');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, 0);
      debouncer.cancelAll();
    });
  });

  group('Throttler', () {
    test('suppresses calls inside the window', () async {
      final throttler = Throttler();
      var calls = 0;
      expect(throttler.run('a', () => calls++, duration: const Duration(milliseconds: 20)), isTrue);
      expect(throttler.run('a', () => calls++, duration: const Duration(milliseconds: 20)), isFalse);
      expect(throttler.run('b', () => calls++, duration: const Duration(milliseconds: 20)), isTrue);
      expect(calls, 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(throttler.run('a', () => calls++, duration: const Duration(milliseconds: 20)), isTrue);
      expect(calls, 3);
      throttler.clear();
    });
  });

  group('retryCall', () {
    test('retries transient failures and returns the successful result', () async {
      var attempts = 0;
      final value = await retryCall<int>(
        task: () async {
          attempts++;
          if (attempts < 3) throw StateError('transient');
          return 42;
        },
        initialDelay: Duration.zero,
        timeout: const Duration(seconds: 2),
      );
      expect(value, 42);
      expect(attempts, 3);
    });

    test('does not retry when retryIf rejects the error', () async {
      var attempts = 0;
      await expectLater(
        retryCall<int>(
          task: () async {
            attempts++;
            throw const FormatException('permanent');
          },
          retryIf: (error) => error is! FormatException,
          initialDelay: Duration.zero,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(attempts, 1);
    });
  });

  group('RefreshGate', () {
    test('gates rebuilds on foreground state', () {
      final gate = RefreshGate();
      expect(gate.shouldRebuild, isTrue);
      gate.setForeground(false);
      expect(gate.shouldRebuild, isFalse);
      expect(gate.foreground, isFalse);
      gate.setForeground(true);
      expect(gate.shouldRebuild, isTrue);
      gate.dispose();
    });

    test('respects the page predicate', () {
      var onDashboard = false;
      final gate = RefreshGate(pageIsDashboard: () => onDashboard);
      expect(gate.shouldRebuild, isFalse);
      onDashboard = true;
      expect(gate.shouldRebuild, isTrue);
      gate.dispose();
    });
  });

  group('config guard', () {
    test('validateConfigText accepts JSON and non-JSON, rejects broken JSON', () {
      expect(validateConfigText('{"outbounds":[]}'), '{"outbounds":[]}');
      expect(validateConfigText('rule: direct\n'), 'rule: direct\n');
      expect(() => validateConfigText('{"a":'), throwsA(isA<ConfigValidationError>()));
    });

    test('AtomicFileWriter never replaces the target on a failed validation', () async {
      final dir = await Directory.systemTemp.createTemp('config_guard_test');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/config.json');
      await target.writeAsString('original');
      const writer = AtomicFileWriter();
      await expectLater(
        writer.write(target, '{"broken":', validate: (value) => throw ConfigValidationError('bad')),
        throwsA(isA<ConfigValidationError>()),
      );
      expect(await target.readAsString(), 'original');
      expect(dir.listSync().where((entry) => entry.path.endsWith('.tmp')), isEmpty);
      await writer.write(target, '{"ok":true}');
      expect(await target.readAsString(), '{"ok":true}');
    });

    test('guardedConfigWrite restores the previous content after a failed commit', () async {
      String stored = 'previous';
      var restored = false;
      await expectLater(
        guardedConfigWrite<String>(
          readPrevious: () async => stored,
          commit: (content) async {
            stored = content;
            throw StateError('bridge rejected');
          },
          restore: (previous) async {
            restored = true;
            stored = previous;
          },
          candidate: '{"new":true}',
        ),
        throwsA(isA<StateError>()),
      );
      expect(restored, isTrue);
      expect(stored, 'previous');
    });

    test('guardedConfigWrite skips rollback when no snapshot could be read', () async {
      var restored = false;
      await expectLater(
        guardedConfigWrite<String>(
          readPrevious: () async => throw StateError('read failed'),
          commit: (_) async => throw StateError('write failed'),
          restore: (_) async => restored = true,
          candidate: 'plain text',
        ),
        throwsA(isA<StateError>()),
      );
      expect(restored, isFalse);
    });
  });

  test('decodeJsonInBackground parses off the calling isolate', () async {
    final value = await decodeJsonInBackground('{"list":[1,2,3]}');
    expect(value, isA<Map<dynamic, dynamic>>());
    expect((value! as Map)['list'], [1, 2, 3]);
  });
}
