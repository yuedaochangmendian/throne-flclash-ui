// Every way the SQLite path can be absent must look identical to the screen:
// the channel's `routes.list` reply. These tests inject a fake reader, so no
// database and no MethodChannel are involved — the default `DataLayer.attach`
// is exercised only for the failures that return before sqlite is opened.

import 'package:flrone/data/route_profiles_source.dart';
import 'package:flutter_test/flutter_test.dart';

RouteProfilesWire validWire() => <String, Object?>{
      'currentId': 1,
      'profiles': [
        <String, Object?>{
          'id': 1,
          'name': 'Default',
          'current': true,
          'isRemote': false,
          'isRaw': false,
          'ruleCount': 3,
          'simpleRuleCount': 1,
        },
      ],
    };

const channelWire = <String, Object?>{
  'currentId': 1,
  'profiles': [
    <String, Object?>{'id': 1, 'name': 'From the channel'},
  ],
};

class FakeReader implements RouteProfilesReader {
  FakeReader(this.wire, {this.throwOnRead = false});

  final RouteProfilesWire wire;
  final bool throwOnRead;
  int reads = 0;
  int closes = 0;

  @override
  RouteProfilesWire listWire() {
    reads++;
    if (throwOnRead) throw StateError('SQL failed');
    return wire;
  }

  @override
  void close() {
    closes++;
  }
}

void main() {
  group('RouteProfilesSource', () {
    test('a valid SQLite answer is returned and the channel is not called', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var channelCalls = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async {
          channelCalls++;
          return channelWire;
        },
        attach: (_) async => reader,
      );

      expect(await source.list(), same(wire));
      expect(channelCalls, 0);
      expect(reader.reads, 1);
    });

    test('attach answering null falls back to the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => null,
        channelFallback: () async => channelWire,
        attach: (_) async => null,
      );

      expect(await source.list(), same(channelWire));
    });

    test('an exception during attach falls back to the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_) async => throw StateError('libsqlite3 missing'),
      );

      expect(await source.list(), same(channelWire));
    });

    test('a SQL or mapping failure falls back to the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_) async => FakeReader(validWire(), throwOnRead: true),
      );

      expect(await source.list(), same(channelWire));
    });

    test('an empty route_profiles table falls back: the host would ensureDefault()', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_) async => FakeReader(<String, Object?>{
              'currentId': 1,
              'profiles': <Object?>[],
            }),
      );

      expect(await source.list(), same(channelWire));
    });

    test('a malformed answer without currentId falls back', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_) async => FakeReader(<String, Object?>{
              'profiles': [validWire()['profiles']],
            }),
      );

      expect(await source.list(), same(channelWire));
    });

    test('the reader is reused, and a failed attach is not retried', () async {
      final reader = FakeReader(validWire());
      var attaches = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_) async {
          attaches++;
          return reader;
        },
      );

      await source.list();
      await source.list();

      expect(attaches, 1);
      expect(reader.reads, 2);

      var failedAttaches = 0;
      final failing = RouteProfilesSource(
        resolvePath: () async => null,
        channelFallback: () async => channelWire,
        attach: (_) async {
          failedAttaches++;
          return null;
        },
      );
      await failing.list();
      await failing.list();
      expect(failedAttaches, 1);
    });

    test('dispose closes the connection and later reads use the channel', () async {
      final reader = FakeReader(validWire());
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_) async => reader,
      );

      await source.list();
      source.dispose();

      expect(reader.closes, 1);
      expect(await source.list(), same(channelWire));
    });
  });

  group('DataLayer.attach fallback (no sqlite opened)', () {
    // These failures all return before `Sqlite.open()`, so the real default
    // attach can be exercised on the host without a native library.

    test('a host that throws for data.path keeps the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => throw StateError('no host'),
        channelFallback: () async => channelWire,
      );

      expect(await source.list(), same(channelWire));
    });

    test('a null data.path reply keeps the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => null,
        channelFallback: () async => channelWire,
      );

      expect(await source.list(), same(channelWire));
    });

    test('a schema version this build does not know keeps the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 18},
        channelFallback: () async => channelWire,
      );

      expect(await source.list(), same(channelWire));
    });

    test('a data.path reply without a path keeps the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'version': 19},
        channelFallback: () async => channelWire,
      );

      expect(await source.list(), same(channelWire));
    });
  });
}
