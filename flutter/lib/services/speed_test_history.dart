// The speed test's history, in the shape Bettbox keeps it.
//
// Bettbox writes a JSON file beside the app's data with a 14-day, 200-record
// window and an atomic rename; this build has no file-access dependency, so the
// same records ride the preference map under one key. The record shape and the
// pruning rules are the parts that matter — a test finished today and a test
// finished last month must survive identically wherever they are stored.
//
// The store is deliberately dependency-free: `prune` is a pure function, so the
// window and the cap are testable without a database or a file system.

import '../box.dart';

/// How long a record stays, and how many are kept. Bettbox's constants.
const speedTestRetention = Duration(days: 14);
const speedTestMaxRecords = 200;

/// The preference key the list lives under.
const speedTestHistoryKey = 'speedTestHistory';

/// One finished run.
class SpeedTestRecord {
  const SpeedTestRecord({
    required this.time,
    this.proxy = '',
    this.provider = '',
    this.protocol = '',
    this.download = 0,
    this.upload = 0,
    this.latency = 0,
    this.jitter = 0,
    this.downloadLatency = 0,
    this.uploadLatency = 0,
    this.rpm = 0,
    this.bytes = 0,
    this.server = const {},
    this.route = const {},
    this.exitIp = '',
    this.error = '',
  });

  /// Milliseconds since the epoch, as the rest of the app stamps times.
  final int time;
  final String proxy, provider, protocol;

  /// Bits per second, as the kernel reports throughput.
  final double download, upload;

  /// Milliseconds.
  final double latency, jitter, downloadLatency, uploadLatency;
  final int rpm;
  final int bytes;

  /// The provider's own server row, and the group path the run dialled.
  final Map<String, Object?> server, route;
  final String exitIp;
  final String error;

  bool get failed => error.isNotEmpty;

  factory SpeedTestRecord.fromState(
    Map<String, Object?> state, {
    required int time,
    String proxy = '',
  }) => SpeedTestRecord(
    time: time,
    proxy: proxy,
    provider: '${state['provider'] ?? ''}',
    protocol: '${state['protocol'] ?? ''}',
    download: _d(state['download']),
    upload: _d(state['upload']),
    latency: _d(state['latency']),
    jitter: _d(state['jitter']),
    downloadLatency: _d(state['downloadLatency']),
    uploadLatency: _d(state['uploadLatency']),
    rpm: (state['rpm'] as num?)?.toInt() ?? 0,
    bytes: (state['bytes'] as num?)?.toInt() ?? 0,
    server: _json(state['server']),
    route: _json(state['route']),
    exitIp: '${state['exitIp'] ?? ''}',
    error: '${state['error'] ?? ''}',
  );

  factory SpeedTestRecord.fromJson(Map<String, Object?> json) => SpeedTestRecord(
    time: (json['time'] as num?)?.toInt() ?? 0,
    proxy: '${json['proxy'] ?? ''}',
    provider: '${json['provider'] ?? ''}',
    protocol: '${json['protocol'] ?? ''}',
    download: _d(json['download']),
    upload: _d(json['upload']),
    latency: _d(json['latency']),
    jitter: _d(json['jitter']),
    downloadLatency: _d(json['downloadLatency']),
    uploadLatency: _d(json['uploadLatency']),
    rpm: (json['rpm'] as num?)?.toInt() ?? 0,
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    server: _json(json['server']),
    route: _json(json['route']),
    exitIp: '${json['exitIp'] ?? ''}',
    error: '${json['error'] ?? ''}',
  );

  Map<String, Object?> toJson() => {
    'time': time,
    'proxy': proxy,
    'provider': provider,
    'protocol': protocol,
    'download': download,
    'upload': upload,
    'latency': latency,
    'jitter': jitter,
    'downloadLatency': downloadLatency,
    'uploadLatency': uploadLatency,
    'rpm': rpm,
    'bytes': bytes,
    'server': server,
    'route': route,
    'exitIp': exitIp,
    'error': error,
  };

  static double _d(Object? value) => (value as num?)?.toDouble() ?? 0;
  static Map<String, Object?> _json(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : const {};
}

/// Applies the retention window and the cap, newest first.
///
/// Pure so the two rules are pinned by tests: a record exactly on the boundary
/// is kept (the window is inclusive), and the cap cuts after sorting so an old
/// burst cannot evict a fresh record.
List<SpeedTestRecord> pruneSpeedTestRecords(
  Iterable<SpeedTestRecord> records,
  int now,
) {
  final oldest = now - speedTestRetention.inMilliseconds;
  final kept = records.where((record) => record.time >= oldest).toList()
    ..sort((a, b) => b.time.compareTo(a.time));
  return kept.take(speedTestMaxRecords).toList();
}

/// Reads, prunes, appends and writes back one record.
///
/// `read` and `write` are injected so the page needs no direct dependency on the
/// controller and the sequencing is testable: the write is a full replace of the
/// pruned list, so a record that aged out disappears on the same write that adds
/// the new one.
Future<List<SpeedTestRecord>> appendSpeedTestRecord(
  SpeedTestRecord record, {
  required Future<List<SpeedTestRecord>> Function() read,
  required Future<bool> Function(List<SpeedTestRecord>) write,
}) async {
  final existing = await read();
  final next = pruneSpeedTestRecords(
    [...existing, record],
    record.time,
  );
  await write(next);
  return next;
}

/// The records currently stored under [speedTestHistoryKey].
Future<List<SpeedTestRecord>> readSpeedTestHistory(BoxController box) async {
  final raw = box.preferences[speedTestHistoryKey];
  if (raw is! List) return const [];
  return pruneSpeedTestRecords(
    [
      for (final item in raw)
        if (item is Map) SpeedTestRecord.fromJson(Map<String, Object?>.from(item)),
    ],
    DateTime.now().millisecondsSinceEpoch,
  );
}

/// Persists [records] under [speedTestHistoryKey].
Future<bool> writeSpeedTestHistory(
  BoxController box,
  List<SpeedTestRecord> records,
) => box.setPreference(
  speedTestHistoryKey,
  [for (final record in records) record.toJson()],
);
