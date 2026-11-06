// The data plane, assembled.
//
// One object owns the connection and hands out the DAOs, so a caller that has a
// [DataLayer] cannot accidentally open a second connection to the same file —
// two writers would still be correct under WAL, but they would also both hold a
// page cache of the same rows and neither would see the other's uncommitted work.
//
// [attach] is deliberately total: every failure (no libsqlite3, no path from the
// host, a schema this build does not know) comes back as null. The caller treats
// null as "keep using the channel", which is the same shape as
// `ThroneKernel.isAvailable` on the kernel side: a capability that is absent
// degrades to the old path instead of taking the screen down.
//
// STATUS: WIRED (one table). `BoxController.routeProfiles` attaches this layer
// on the first route-list read and asks [routeProfiles] for `routes.list`'s wire
// shape; `RouteProfilesSource` keeps the channel as the answer whenever anything
// above is absent or fails. `groups` is still the un-wired vertical slice — it
// has no production caller, and release AOT tree-shakes that DAO. The
// null-degradation contract is unchanged: widening the data plane means adding
// a DAO, never making a screen aware of where its rows came from.

import 'db.dart';
import 'groups_dao.dart';
import 'route_profiles_dao.dart';

/// What `data.path` answers: where the file is, and the schema version the host
/// has it at.
class DatabaseLocation {
  const DatabaseLocation(this.path, this.version);

  final String path;
  final int version;

  static DatabaseLocation? parse(Object? reply) {
    if (reply is! Map) return null;
    final path = reply['path'];
    if (path is! String || path.isEmpty) return null;
    final version = reply['version'];
    return DatabaseLocation(path, version is int ? version : -1);
  }
}

class DataLayer {
  DataLayer._(this._db)
      : groups = GroupsDao(_db),
        routeProfiles = RouteProfilesDao(_db);

  final DataDatabase _db;

  /// The un-wired slice: reads `groups`. Kept because it proves the FFI
  /// connection works and pins the column names, but no screen calls it yet.
  final GroupsDao groups;

  /// The live slice: reproduces `routes.list` from Room's file.
  final RouteProfilesDao routeProfiles;

  /// The file behind this layer, for diagnostics.
  String get path => _db.path;

  /// Opens the app database, or returns null.
  ///
  /// [resolvePath] asks the host once. It is a callback rather than a
  /// `BoxController` so this file does not depend on the channel layer — the
  /// dependency points one way, and the data plane can be tested without one.
  ///
  /// [readOnly] is passed through: a build that has not yet moved any writes
  /// should open the file read-only, so a bug here cannot damage Room's data.
  static Future<DataLayer?> attach({
    required Future<Object?> Function() resolvePath,
    bool readOnly = true,
  }) async {
    final Object? reply;
    try {
      reply = await resolvePath();
    } catch (_) {
      // No host, no channel, or the host refused. Stay on the channel path.
      return null;
    }
    final location = DatabaseLocation.parse(reply);
    if (location == null) return null;
    // A host that reports a version this build was not written against is not a
    // reason to guess: the columns may have moved, and reading them by name
    // would silently return the wrong field rather than fail.
    if (location.version >= 0 && location.version != roomSchemaVersion) {
      return null;
    }
    final DataDatabase db;
    try {
      final opened = DataDatabase.openAt(location.path, readOnly: readOnly);
      if (opened == null) return null;
      db = opened;
    } on SchemaMismatch {
      return null;
    } catch (_) {
      return null;
    }
    return DataLayer._(db);
  }

  void close() => _db.close();
}
