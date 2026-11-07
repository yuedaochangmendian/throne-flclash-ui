// The one place that decides where the route profile list comes from.
//
// STATUS: WIRED. `BoxController.routeProfiles` owns one of these; both route
// screens call `list()` and never know whether SQLite or the channel answered.
// That is the same contract `ThroneKernel.isAvailable` uses on the kernel side:
// a capability that is absent degrades to the old path instead of taking the
// screen down.
//
// An attach can fail permanently (a schema this build does not know) or
// transiently (the host's `data.path` raced a cold start, the file was locked
// by a checkpoint). A permanent failure is never retried — the schema cannot
// change while the host process is alive. A transient one is retried a bounded
// number of times, one attempt per read, and `retryFailed()` (called by the
// controller on app resume) restarts that budget. `invalidate()` drops a
// healthy connection so the next read re-asks `data.path` and re-checks the
// schema, for the flows that replace the database file under a live app.
//
// This file does not depend on `box.dart`. It takes two callbacks so the data
// plane keeps pointing one way (channel -> data) and can be tested without a
// MethodChannel.

import 'data_layer.dart' show AttachFailure, DataLayer;

/// The `routes.list` reply shape.
typedef RouteProfilesWire = Map<String, Object?>;

/// What the source needs from an attached data layer: one read and one close.
/// Narrow on purpose — a test can supply a fake reader without opening sqlite.
abstract class RouteProfilesReader {
  RouteProfilesWire listWire();
  void close();
}

/// The injectable attach: the default opens `DataLayer`, a test supplies a
/// fake. The optional [onFailure] listener receives the reason when the answer
/// is null; an attach that ignores it is still a valid attach, and its null is
/// then treated as permanent (an unclassified failure is not worth a retry
/// storm).
typedef RouteProfilesAttach = Future<RouteProfilesReader?> Function(
  Future<dynamic> Function() resolvePath, {
  void Function(AttachFailure reason)? onFailure,
});

class _DataLayerReader implements RouteProfilesReader {
  const _DataLayerReader(this._layer);

  final DataLayer _layer;

  @override
  RouteProfilesWire listWire() => _layer.routeProfiles.listWire();

  @override
  void close() => _layer.close();
}

/// Prefers the Room file; falls back to `routes.list` on every failure.
class RouteProfilesSource {
  RouteProfilesSource({
    required this.resolvePath,
    required this.channelFallback,
    RouteProfilesAttach? attach,
  }) : _attach = attach ?? _defaultAttach;

  /// Asks the host once for `data.path`. A callback, not a controller, so the
  /// data plane never imports the channel layer.
  final Future<dynamic> Function() resolvePath;

  /// The old path: the `routes.list` channel reply.
  final Future<dynamic> Function() channelFallback;

  final RouteProfilesAttach _attach;

  RouteProfilesReader? _reader;
  bool _disposed = false;

  /// Set when the failure cannot change inside this app run: a schema version
  /// mismatch, an exception from the attach itself, or an unclassified null.
  bool _permanent = false;

  /// Transient failures seen so far; one attempt is spent per read.
  int _transientAttempts = 0;

  /// The retry budget for a transient failure. Three reads span the cold-start
  /// race without turning a broken device into a polling loop.
  static const _maxTransientAttempts = 3;

  static Future<RouteProfilesReader?> _defaultAttach(
      Future<dynamic> Function() resolvePath,
      {void Function(AttachFailure reason)? onFailure}) async {
    // readOnly: the data plane has not moved any writes, so a bug here cannot
    // damage Room's data. `attach` is total — every failure answers null, with
    // the reason reported through [onFailure].
    final layer = await DataLayer.attach(
      resolvePath: () async => await resolvePath(),
      readOnly: true,
      onFailure: onFailure,
    );
    return layer == null ? null : _DataLayerReader(layer);
  }

  /// `routes.list`'s shape, from SQLite when it can, from the channel otherwise.
  Future<dynamic> list() async {
    final reader = await _attached();
    if (reader != null) {
      try {
        final wire = reader.listWire();
        final profiles = wire['profiles'];
        // An empty table is not a valid answer. On the host side
        // `RouteManager.all()` calls `ensureDefault()` and writes a profile; a
        // read-only Dart connection must not do that. Let the host answer.
        // A missing `currentId` means the `settings` read went wrong too.
        if (profiles is List && profiles.isNotEmpty &&
            wire.containsKey('currentId')) {
          return wire;
        }
      } catch (_) {
        // A SQL error, a moved column, a bad row: fall through to the channel.
        // Nothing here is allowed to reach the screen as an error.
      }
    }
    return await channelFallback();
  }

  Future<RouteProfilesReader?> _attached() async {
    final cached = _reader;
    if (cached != null) return cached;
    if (_disposed || _permanent) return null;
    if (_transientAttempts >= _maxTransientAttempts) return null;
    AttachFailure? failure;
    final RouteProfilesReader? reader;
    try {
      reader = await _attach(resolvePath, onFailure: (reason) {
        failure = reason;
      });
    } catch (_) {
      // The attach itself threw. The reason is unknown, and an unknown failure
      // is not worth retrying inside this run.
      _permanent = true;
      return null;
    }
    if (reader != null) {
      if (_disposed) {
        // dispose() won the race with the async attach.
        reader.close();
        return null;
      }
      _transientAttempts = 0;
      return _reader = reader;
    }
    if (failure == null || failure == AttachFailure.schemaVersion) {
      // Either no reason was reported (an unclassified null) or the file is at
      // a version this build does not know — neither changes before restart.
      _permanent = true;
    } else {
      // hostPath / openFailed: the next read gets another attempt.
      _transientAttempts++;
    }
    return null;
  }

  /// Restarts the retry budget for a transient failure. Called by the
  /// controller on app resume: a cold start can race the host's first
  /// `data.path`, and by the time the user comes back the answer exists.
  /// A healthy reader and a permanent failure are both left alone.
  void retryFailed() {
    if (_disposed || _reader != null || _permanent) return;
    _transientAttempts = 0;
  }

  /// Drops the attached reader — if any — so the next read re-attaches from
  /// scratch: a fresh `data.path`, a fresh schema check, a fresh connection.
  /// For the flows that replace the database file under a live app (backup
  /// restore). A plain resume does not need this: `PRAGMA user_version` cannot
  /// change while the host process that owns the schema is alive.
  void invalidate() {
    final reader = _reader;
    _reader = null;
    reader?.close();
    _transientAttempts = 0;
    // `_permanent` survives: a schema this build does not know is still not
    // known after re-asking, and nothing in this process can change that.
  }

  void dispose() {
    _disposed = true;
    _reader?.close();
    _reader = null;
  }
}
