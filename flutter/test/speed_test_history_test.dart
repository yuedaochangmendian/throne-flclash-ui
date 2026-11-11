// The history's two rules, pinned without a controller or a file system.
//
// `pruneSpeedTestRecords` is pure, so the retention window and the record cap
// are testable directly. Both are the behaviours a reader would notice going
// wrong: a test from this morning disappearing, or last month's burst pushing
// today's result out.

import 'package:flrone/services/speed_test_history.dart';
import 'package:flutter_test/flutter_test.dart';

SpeedTestRecord _record(int time, {double download = 0}) =>
    SpeedTestRecord(time: time, download: download);

void main() {
  group('pruneSpeedTestRecords', () {
    test('keeps a record exactly on the retention boundary', () {
      final now = 1_700_000_000_000;
      final boundary = now - speedTestRetention.inMilliseconds;
      final kept = pruneSpeedTestRecords([_record(boundary)], now);

      expect(kept, hasLength(1));
    });

    test('drops a record one millisecond past the boundary', () {
      final now = 1_700_000_000_000;
      final stale = now - speedTestRetention.inMilliseconds - 1;

      expect(pruneSpeedTestRecords([_record(stale)], now), isEmpty);
    });

    test('sorts newest first', () {
      final now = 1_700_000_000_000;
      final kept = pruneSpeedTestRecords(
        [
          _record(now - 3000),
          _record(now - 1000),
          _record(now - 2000),
        ],
        now,
      );

      expect(kept.map((r) => r.time), [now - 1000, now - 2000, now - 3000]);
    });

    test('cuts after sorting, so an old burst cannot evict a fresh record', () {
      final now = 1_700_000_000_000;
      final records = [
        _record(now, download: 99),
        for (var i = 1; i <= speedTestMaxRecords + 5; i++)
          _record(now - i * 1000, download: i.toDouble()),
      ];

      final kept = pruneSpeedTestRecords(records, now);

      expect(kept, hasLength(speedTestMaxRecords));
      // The newest record survives even though it was appended first.
      expect(kept.first.download, 99);
    });

    test('an empty input stays empty', () {
      expect(pruneSpeedTestRecords(const [], 1_700_000_000_000), isEmpty);
    });
  });

  group('SpeedTestRecord', () {
    test('round-trips through JSON', () {
      final record = SpeedTestRecord(
        time: 1_700_000_000_000,
        proxy: 'TOKYO',
        provider: 'cloudflare',
        protocol: 'h2',
        download: 8.2e7,
        upload: 1.5e7,
        latency: 23.4,
        jitter: 3.1,
        downloadLatency: 41,
        uploadLatency: 55,
        rpm: 2600,
        bytes: 120_000_000,
        server: const {'country': 'JP', 'city': 'Tokyo'},
        route: const {
          'chains': ['Proxy', 'TOKYO'],
        },
        exitIp: '203.0.113.9',
      );

      final back = SpeedTestRecord.fromJson(record.toJson());

      expect(back.time, record.time);
      expect(back.proxy, 'TOKYO');
      expect(back.provider, 'cloudflare');
      expect(back.download, 8.2e7);
      expect(back.latency, 23.4);
      expect(back.server['city'], 'Tokyo');
      expect(back.route['chains'], ['Proxy', 'TOKYO']);
      expect(back.exitIp, '203.0.113.9');
    });

    test('a kernel snapshot becomes a record', () {
      final record = SpeedTestRecord.fromState(
        {
          'provider': 'apple',
          'protocol': 'h1',
          'download': 5.0e7,
          'upload': 1.0e7,
          'latency': 12.0,
          'jitter': 1.5,
          'rpm': 3200,
          'bytes': 90000000,
          'server': {'country': 'US', 'colo': 'LAX'},
          'route': {
            'chains': ['Proxy', 'Node A'],
          },
          'exitIp': '198.51.100.4',
        },
        time: 1_700_000_000_000,
      );

      expect(record.provider, 'apple');
      expect(record.download, 5.0e7);
      expect(record.latency, 12.0);
      expect(record.server['colo'], 'LAX');
      expect(record.exitIp, '198.51.100.4');
      expect(record.failed, isFalse);
    });

    test('a failed run records its verdict and reads as failed', () {
      final record = SpeedTestRecord.fromState(
        {'error': 'blocked'},
        time: 1,
      );

      expect(record.failed, isTrue);
      expect(record.error, 'blocked');
    });

    test('missing keys default instead of throwing', () {
      final record = SpeedTestRecord.fromJson(const {});

      expect(record.time, 0);
      expect(record.download, 0);
      expect(record.upload, 0);
      expect(record.server, isEmpty);
      expect(record.route, isEmpty);
      expect(record.failed, isFalse);
    });
  });

  group('appendSpeedTestRecord', () {
    test('adds the record and writes the pruned list back', () {
      final now = 1_700_000_000_000;
      final stale = now - speedTestRetention.inMilliseconds - 1;
      List<SpeedTestRecord>? written;

      return appendSpeedTestRecord(
        _record(now, download: 42),
        read: () async => [_record(stale)],
        write: (records) async {
          written = records;
          return true;
        },
      ).then((next) {
        expect(next, hasLength(1));
        expect(next.single.download, 42);
        expect(written, same(next));
      });
    });
  });
}
