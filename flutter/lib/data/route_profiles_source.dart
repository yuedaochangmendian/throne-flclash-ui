// The one place that decides where the route profile list comes from.
//
// STATUS: WIRED. `BoxController.routeProfiles` owns one of these; both route
// screens call `list()` and never know whether SQLite or the channel answered.
// That is the same contract `ThroneKernel.isAvailable` uses on the kernel side:
// a capability that is absent degrades to the old path instead of taking the
// screen down.
//
// This file does not depend on `box.dart`. It takes two callbacks so the data
// plane keeps pointing one way (channel -> data) and can be tested without a
// MethodChannel.

import 'data_layer.dart';

/// The `routes.list` reply shape.
typedef RouteProfilesWire = Map<String, Object?>;

/// What the source needs from an attached data layer: one read and one close.
/// Narrow on purpose — a test can supply a fake reader without opening sqlite.
abstract class RouteProfilesReader {
  RouteProfilesWire listWire();
  void close();
}

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
    Future<RouteProfilesReader?> Function(Future<dynamic> Function())? attach,
  }) : _attach = attach ?? _defaultAttach;

  /// Asks the host once for `data.path`. A callback, not a controller, so the
  /// data plane never imports the channel layer.
  final Future<dynamic> Function() resolvePath;

  /// The old path: the `routes.list` channel reply.
  final Future<dynamic> Function() channelFallback;

  final Future<RouteProfilesReader?> Function(Future<dynamic> Function())
      _attach;

  RouteProfilesReader? _reader;
  bool _attachFailed = false;
  bool _disposed = false;

  static Future<RouteProfilesReader?> _defaultAttach(
      Future<dynamic> Function() resolvePath) async {
    // readOnly: the data plane has not moved any writes, so a bug here cannot
    // damage Room's data. `attach` is total — every failure answers null.
    final layer = await DataLayer.attach(
      resolvePath: () async => await resolvePath(),
      readOnly: true,
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
    if (_disposed || _attachFailed) return null;
    try {
      final reader = await _attach(resolvePath);
      if (reader == null) {
        // No library, no path, unexpected schema. Do not retry on every screen
        // open; the answer will not change until the app restarts.
        _attachFailed = true;
        return null;
      }
      if (_disposed) {
        // dispose() won the race with the async attach.
        reader.close();
        return null;
      }
      return _reader = reader;
    } catch (_) {
      _attachFailed = true;
      return null;
    }
  }

  void dispose() {
    _disposed = true;
    _reader?.close();
    _reader = null;
  }
}
