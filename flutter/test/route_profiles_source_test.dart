// Every way the SQLite path can be absent must look identical to the screen:
// the channel's `routes.list` reply. These tests inject a fake reader, so no
// database and no MethodChannel are involved — the default `DataLayer.attach`
// is exercised only for the failures that return before sqlite is opened.

import 'package:flrone/data/data_layer.dart' show AttachFailure;
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
        attach: (_, {onFailure}) async => reader,
      );

      expect(await source.list(), same(wire));
      expect(channelCalls, 0);
      expect(reader.reads, 1);
    });

    test('concurrent first reads share one attach', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var attaches = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_, {onFailure}) async {
          attaches++;
          // A real attach awaits the channel; let the second read overlap it.
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return reader;
        },
      );

      final first = source.list();
      final second = source.list();
      expect(await first, same(wire));
      expect(await second, same(wire));
      expect(attaches, 1,
          reason: 'the loser of the attach race used to leak its connection');
      expect(reader.reads, 2);
    });

    test('a reader that fails mid-read is closed and never retried', () async {
      final bad = FakeReader(validWire(), throwOnRead: true);
      var attaches = 0;
      var channelCalls = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async {
          channelCalls++;
          return channelWire;
        },
        attach: (_, {onFailure}) async {
          attaches++;
          return bad;
        },
      );

      expect(await source.list(), same(channelWire));
      expect(bad.closes, 1, reason: 'a broken reader must not stay cached');

      // SQL cannot heal inside this run: no re-attach, the channel answers.
      expect(await source.list(), same(channelWire));
      expect(attaches, 1);
      expect(bad.reads, 1);
      expect(channelCalls, 2);
    });

    test('attach answering null falls back to the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => null,
        channelFallback: () async => channelWire,
        attach: (_, {onFailure}) async => null,
      );

      expect(await source.list(), same(channelWire));
    });

    test('an exception during attach falls back to the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_, {onFailure}) async => throw StateError('libsqlite3 missing'),
      );

      expect(await source.list(), same(channelWire));
    });

    test('a SQL or mapping failure falls back to the channel', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_, {onFailure}) async => FakeReader(validWire(), throwOnRead: true),
      );

      expect(await source.list(), same(channelWire));
    });

    test('an empty route_profiles table falls back: the host would ensureDefault()', () async {
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_, {onFailure}) async => FakeReader(<String, Object?>{
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
        attach: (_, {onFailure}) async => FakeReader(<String, Object?>{
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
        attach: (_, {onFailure}) async {
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
        attach: (_, {onFailure}) async {
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
        attach: (_, {onFailure}) async => reader,
      );

      await source.list();
      source.dispose();

      expect(reader.closes, 1);
      expect(await source.list(), same(channelWire));
    });
  });

  group('attach retry and invalidation', () {
    test('a transient failure (cold-start data.path race) is retried on the next read', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var attempts = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => null,
        channelFallback: () async => channelWire,
        attach: (resolve, {onFailure}) async {
          attempts++;
          if (attempts < 2) {
            onFailure?.call(AttachFailure.hostPath);
            return null;
          }
          return reader;
        },
      );

      expect(await source.list(), same(channelWire));
      expect(await source.list(), same(wire));
      expect(attempts, 2);
    });

    test('a schema version mismatch is permanent: no retry, not even retryFailed()', () async {
      var attempts = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 18},
        channelFallback: () async => channelWire,
        attach: (resolve, {onFailure}) async {
          attempts++;
          onFailure?.call(AttachFailure.schemaVersion);
          return null;
        },
      );

      await source.list();
      await source.list();
      source.retryFailed();
      await source.list();

      expect(attempts, 1);
    });

    test('transient attempts are capped', () async {
      var attempts = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => null,
        channelFallback: () async => channelWire,
        attach: (resolve, {onFailure}) async {
          attempts++;
          onFailure?.call(AttachFailure.hostPath);
          return null;
        },
      );

      for (var i = 0; i < 5; i++) {
        await source.list();
      }

      expect(attempts, 3);
    });

    test('retryFailed() restarts the transient budget', () async {
      var attempts = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => null,
        channelFallback: () async => channelWire,
        attach: (resolve, {onFailure}) async {
          attempts++;
          onFailure?.call(AttachFailure.hostPath);
          return null;
        },
      );

      for (var i = 0; i < 5; i++) {
        await source.list();
      }
      expect(attempts, 3);

      source.retryFailed();
      await source.list();
      expect(attempts, 4);
    });

    test('retryFailed() does not touch a healthy reader', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var attaches = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_, {onFailure}) async {
          attaches++;
          return reader;
        },
      );

      await source.list();
      await source.list();
      source.retryFailed();
      await source.list();

      expect(attaches, 1);
      expect(reader.reads, 3);
      expect(reader.closes, 0);
    });

    test('invalidate() closes the reader and the next read re-attaches', () async {
      final first = FakeReader(validWire());
      final second = FakeReader(validWire());
      final readers = [first, second];
      var attaches = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (_, {onFailure}) async => readers[attaches++],
      );

      await source.list();
      source.invalidate();

      expect(first.closes, 1);

      await source.list();
      expect(attaches, 2);
      expect(second.reads, 1);
    });

    test('invalidate() does not revive a permanent failure', () async {
      var attempts = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 18},
        channelFallback: () async => channelWire,
        attach: (resolve, {onFailure}) async {
          attempts++;
          onFailure?.call(AttachFailure.schemaVersion);
          return null;
        },
      );

      await source.list();
      source.invalidate();
      await source.list();

      expect(attempts, 1);
    });

    test('an openFailed attach is retried like a transient one', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var attempts = 0;
      final source = RouteProfilesSource(
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 19},
        channelFallback: () async => channelWire,
        attach: (resolve, {onFailure}) async {
          attempts++;
          if (attempts < 2) {
            onFailure?.call(AttachFailure.openFailed);
            return null;
          }
          return reader;
        },
      );

      expect(await source.list(), same(channelWire));
      expect(await source.list(), same(wire));
      expect(attempts, 2);
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
