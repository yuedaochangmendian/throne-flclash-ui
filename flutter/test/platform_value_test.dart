import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/core/platform_value.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('platform value normalization', () {
    test('the codec-shaped map reproduces the old cast failure', () {
      // StandardMessageCodec decodes a Kotlin Map<*, *> into exactly this shape.
      final Map<Object?, Object?> raw = <Object?, Object?>{
        'coreConfig': '{}',
        'needXray': true,
      };
      expect(() => raw as Map<String, dynamic>, throwsA(isA<TypeError>()));

      final normalized = asStringKeyedMap(raw, context: 'config.build');
      expect(normalized, isA<Map<String, dynamic>>());
      expect(normalized['coreConfig'], '{}');
      expect(normalized['needXray'], isTrue);
    });

    test('nested maps and lists are normalized recursively', () {
      final child = <Object?, Object?>{'mode': 'rule'};
      final raw = <Object?, Object?>{
        'child': child,
        'items': <Object?>[child, <Object?, Object?>{'id': 7}, 'plain'],
      };
      final out = asStringKeyedMap(raw);
      expect(out['child'], isA<Map<String, dynamic>>());
      final items = out['items'] as List;
      expect(items, hasLength(3));
      expect(items[0], isA<Map<String, dynamic>>());
      expect((items[1] as Map<String, dynamic>)['id'], 7);
      expect(items[2], 'plain');
    });

    test('non-string keys are stringified instead of throwing', () {
      final out = asStringKeyedMap(<Object?, Object?>{1: 'one', null: 'none'});
      expect(out['1'], 'one');
      expect(out['null'], 'none');
    });

    test('typed data is preserved (app icons travel as Uint8List)', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(identical(normalizePlatformValue(bytes), bytes), isTrue);
      final wrapped = asStringKeyedMap(<Object?, Object?>{'icon': bytes});
      expect(identical(wrapped['icon'], bytes), isTrue);
    });

    test('scalars and null pass through unchanged', () {
      expect(normalizePlatformValue(42), 42);
      expect(normalizePlatformValue('x'), 'x');
      expect(normalizePlatformValue(true), isTrue);
      expect(normalizePlatformValue(null), isNull);
    });

    test('a bad wire shape fails with a readable error', () {
      expect(
        () => asStringKeyedMap('not a map', context: 'config.build'),
        throwsA(isA<FormatException>().having(
            (error) => error.message, 'message', contains('config.build'))),
      );
      expect(() => asStringKeyedMap(null), throwsA(isA<FormatException>()));
      expect(() => asStringKeyedRows(42), throwsA(isA<FormatException>()));
    });

    test('rows keeps map entries and drops the rest', () {
      final rows = asStringKeyedRows(<Object?>[
        <Object?, Object?>{'id': 1},
        'junk',
        <Object?, Object?>{'id': 2},
      ]);
      expect(rows, hasLength(2));
      expect(rows.first, isA<Map<String, dynamic>>());
      expect(rows.last['id'], 2);
    });
  });

  group('method channel boundary', () {
    test('BoxController.call returns a normalized config.build reply', () async {
      const channel = MethodChannel('test.platform-value');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      // The mock goes through StandardMessageCodec, so the handler's map comes
      // back as `_Map<Object?, Object?>` just like the real Kotlin bridge.
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'config.build':
            return <Object?, Object?>{
              'coreConfig': '{}',
              'xrayFullConfigs': <Object?>['a', 'b'],
              'nested': <Object?, Object?>{'interval': 30},
            };
          case 'config.warpParams':
            return <Object?, Object?>{
              'proxy': 'socks5://127.0.0.1:4000',
              'hosts': <Object?>['api.cloudflare.com'],
            };
          case 'apps.icon':
            return Uint8List.fromList([1, 2, 3]);
          default:
            return null;
        }
      });

      final box = BoxController(
        channel: channel,
        events: Stream<dynamic>.empty(),
      );
      addTearDown(box.dispose);

      final built = await box.call('config.build');
      // These are the two casts that used to crash startup.
      expect(built, isA<Map<String, dynamic>>());
      expect(() => built as Map<String, dynamic>, returnsNormally);
      expect(built['nested'], isA<Map<String, dynamic>>());
      expect((built['nested'] as Map<String, dynamic>)['interval'], 30);
      expect(built['xrayFullConfigs'], isA<List>());

      final params = await box.call('config.warpParams');
      expect(params, isA<Map<String, dynamic>>());
      expect((params as Map<String, dynamic>)['proxy'],
          'socks5://127.0.0.1:4000');

      expect(await box.call('apps.icon'), isA<Uint8List>());
    });

    test('EventChannel payloads are normalized before dispatch', () async {
      const channel = MethodChannel('test.platform-value-events');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ready') {
          return <Object?, Object?>{
            'version': '3.2.18',
            'coreVersion': 'test',
            'systemAccentColor': 0xff007aff,
            'dashboard': <Object?, Object?>{},
            'profiles': <Object?>[],
            'settings': <Object?, Object?>{},
            'capabilities': <Object?, Object?>{},
            'preferences': <Object?, Object?>{},
            'tools': <Object?, Object?>{},
            'diagnostics': <Object?, Object?>{
              'stun': <Object?, Object?>{},
              'quality': <Object?, Object?>{},
            },
          };
        }
        return null; // ffi.mode is a no-op when the rebuilt core is absent.
      });

      final events = StreamController<dynamic>();
      addTearDown(events.close);
      final box = BoxController(channel: channel, events: events.stream);
      addTearDown(box.dispose);
      await box.initialize();
      expect(box.startupError, isNull);

      events.add(<Object?, Object?>{
        'type': 'tools',
        'value': <Object?, Object?>{'nested': <Object?, Object?>{'ok': 1}},
      });
      await Future<void>.delayed(Duration.zero);

      expect(box.toolState, isA<Map<String, dynamic>>());
      expect(box.toolState['nested'], isA<Map<String, dynamic>>());
      expect((box.toolState['nested'] as Map<String, dynamic>)['ok'], 1);
    });
  });

  group('payload helpers', () {
    // Both boundaries normalize, so json()/rows() only cast. Re-normalizing there used to copy
    // the entire startup catalog a second time; these guard the copy from coming back.
    test('an already-normalized map is returned as is', () {
      final map = <String, dynamic>{'a': 1};
      expect(identical(json(map), map), isTrue);
    });

    test('a map that skipped the boundary is still normalized', () {
      final raw = <Object?, Object?>{'a': 1, 'nested': <Object?, Object?>{'b': 2}};
      final value = json(raw);
      expect(value, isA<Map<String, dynamic>>());
      expect(value['nested'], isA<Map<String, dynamic>>());
    });

    test('rows keeps normalized rows and normalizes stragglers', () {
      final row = <String, dynamic>{'id': 1};
      final out = rows(<Object?>[row, 'not a map', <Object?, Object?>{'id': 2}]);
      expect(identical(out.first, row), isTrue);
      expect(out.map((item) => item['id']), [1, 2]);
    });

    test('a missing list is an empty result, not an exception', () {
      expect(rows(null), isEmpty);
      expect(json('text'), isEmpty);
    });
  });
}
