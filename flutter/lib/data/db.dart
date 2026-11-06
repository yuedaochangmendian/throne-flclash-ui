// The app's own database, opened on the Dart side.
//
// `sager_net.db` is Room's file (six tables: proxy groups, proxies, route
// profiles, route rules, settings, markers). It is already opened with
// WRITE_AHEAD_LOGGING — SagerDatabase says so, and the comment there names the
// reason: WAL lets a reader in one process run while the other writes. Nothing
// stops a third connection in this isolate from doing the same, which is what
// this file does. Room stays the writer for the paths the host still owns; Dart
// reads, and writes only where the host has stopped.
//
// The path comes from the host once (`data.path`), because Dart cannot derive
// `/data/data/<pkg>/databases` without a package name it does not have. That is
// a one-shot platform fact, not a data-plane call: after this file opens, the
// channel is not in the query path at all.

import 'sqlite.dart';

/// Room's `@Database(version = …)`. Duplicated here on purpose: if the host
/// bumps the schema and this constant does not follow, [DataDatabase.openAt]
/// refuses to write rather than reading columns that moved.
///
/// `tools/diagnostics/schema_audit.py` compares the two on every push.
const roomSchemaVersion = 19;

/// Room's file name (`Key.DB_PROFILE`).
const databaseFileName = 'sager_net.db';

/// Thrown when the file is present but not the shape this build understands.
class SchemaMismatch implements Exception {
  SchemaMismatch(this.found, this.expected);

  final int found;
  final int expected;

  @override
  String toString() =>
      'SchemaMismatch: database is at version $found, this build expects $expected';
}

/// A connection to the app database.
///
/// Queries are synchronous (sqlite3 is), so a call blocks the isolate that made
/// it. The vertical slice keeps them on the UI isolate because every statement
/// here is a single-table read under a few hundred rows; the moment a query
/// grows past that, it belongs on a long-lived DB isolate — the same shape as
/// `KernelWorker`, and for the same reason.
class DataDatabase implements Queryable {
  DataDatabase._(this._db);

  final SqliteDatabase _db;

  /// The file this connection holds open.
  String get path => _db.path;

  /// Opens [path], or returns null when the platform has no libsqlite3 or the
  /// file cannot be opened. A null result means "stay on the channel": the
  /// caller keeps using `profiles.list` and friends.
  ///
  /// [readOnly] defaults to false because the vertical slice writes nothing yet
  /// but must prove it can; pass true to run purely as an observer.
  static DataDatabase? openAt(String path, {bool readOnly = false}) {
    final sqlite = Sqlite.open();
    if (sqlite == null) return null;
    final db = sqlite.openDatabase(path, readOnly: readOnly);
    if (db == null) return null;
    final opened = DataDatabase._(db);
    try {
      opened._checkSchema();
      return opened;
    } on SchemaMismatch {
      db.close();
      rethrow;
    } catch (_) {
      db.close();
      return null;
    }
  }

  /// Room stores the schema version in `PRAGMA user_version`; a file migrated by
  /// a newer host build answers with a number this one does not know, and
  /// reading it anyway would map columns by position into the wrong fields.
  void _checkSchema() {
    final rows = _db.query('PRAGMA user_version');
    final version = rows.isEmpty ? 0 : (rows.first.values.first as int? ?? 0);
    // A fresh file (0) is not this app's database at all; treat it as a mismatch
    // rather than creating tables that Room would then fight over.
    if (version != roomSchemaVersion) {
      throw SchemaMismatch(version, roomSchemaVersion);
    }
  }

  /// Rows of [sql]. See [SqliteDatabase.query] for the value shapes.
  List<SqlRow> query(String sql, [List<Object?> params = const []]) =>
      _db.query(sql, params);

  /// Runs [sql], returning the number of rows changed.
  int execute(String sql, [List<Object?> params = const []]) =>
      _db.execute(sql, params);

  /// The rowid of the last successful INSERT.
  int get lastInsertRowId => _db.lastInsertRowId;

  void close() => _db.close();
}
