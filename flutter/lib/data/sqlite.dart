// The platform's SQLite, opened over dart:ffi instead of a Flutter plugin.
//
// Android has shipped libsqlite3.so since API 21 and this app's floor is 24, so
// there is nothing to package and nothing to register: `DynamicLibrary.open`
// finds the system file, and the entry points below are all a DAO needs.
//
// The alternative, sqflite, is a plugin — and a plugin in this module is not
// free. `flutter build aar` publishes an AAR whose GeneratedPluginRegistrant the
// host loads by reflection and, on failure, **swallows**; BboxFlutterActivity's
// `registerScannerPlugin` exists entirely because of that swallow. A
// DynamicLibrary has no registrant, so the data plane can leave the channel
// without adding a second plugin to babysit.
//
// Everything here is synchronous, because sqlite3 is: a call blocks whichever
// isolate made it. The DAO layer runs on the DB isolate (see db.dart) so the UI
// isolate never pays for a query.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Result codes, from sqlite3.h. Only the three that change control flow.
const _ok = 0;
const _row = 100;
const _done = 101;

// Open flags. FULLMUTEX is deliberate: the DB isolate and a diagnostic read from
// the UI isolate may overlap, and serialising inside sqlite is cheaper than a
// second lock on this side.
const _openReadOnly = 0x00000001;
const _openReadWrite = 0x00000002;
const _openCreate = 0x00000004;
const _openFullMutex = 0x00010000;

// sqlite3_column_type results.
const _typeInteger = 1;
const _typeFloat = 2;
const _typeText = 3;
const _typeBlob = 4;

/// `SQLITE_TRANSIENT`: the destructor value that tells sqlite to copy the buffer
/// it was handed, so the Dart allocation can be freed as soon as the call returns.
final Pointer<NativeFunction<Void Function(Pointer<Void>)>> _transient =
    Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(-1);

typedef _OpenC = Int32 Function(Pointer<Utf8> name, Pointer<Pointer<Void>> out,
    Int32 flags, Pointer<Utf8> vfs);
typedef _OpenD = int Function(Pointer<Utf8> name, Pointer<Pointer<Void>> out,
    int flags, Pointer<Utf8> vfs);

typedef _CloseC = Int32 Function(Pointer<Void> db);
typedef _CloseD = int Function(Pointer<Void> db);

typedef _PrepareC = Int32 Function(Pointer<Void> db, Pointer<Utf8> sql, Int32 n,
    Pointer<Pointer<Void>> stmt, Pointer<Pointer<Utf8>> tail);
typedef _PrepareD = int Function(Pointer<Void> db, Pointer<Utf8> sql, int n,
    Pointer<Pointer<Void>> stmt, Pointer<Pointer<Utf8>> tail);

typedef _StepC = Int32 Function(Pointer<Void> stmt);
typedef _StepD = int Function(Pointer<Void> stmt);

typedef _FinalizeC = Int32 Function(Pointer<Void> stmt);
typedef _FinalizeD = int Function(Pointer<Void> stmt);

typedef _BindIntC = Int32 Function(
    Pointer<Void> stmt, Int32 index, Int64 value);
typedef _BindIntD = int Function(Pointer<Void> stmt, int index, int value);

typedef _BindDoubleC = Int32 Function(
    Pointer<Void> stmt, Int32 index, Double value);
typedef _BindDoubleD = int Function(
    Pointer<Void> stmt, int index, double value);

typedef _BindTextC = Int32 Function(
    Pointer<Void> stmt,
    Int32 index,
    Pointer<Utf8> value,
    Int32 length,
    Pointer<NativeFunction<Void Function(Pointer<Void>)>> destroy);
typedef _BindTextD = int Function(
    Pointer<Void> stmt,
    int index,
    Pointer<Utf8> value,
    int length,
    Pointer<NativeFunction<Void Function(Pointer<Void>)>> destroy);

typedef _BindBlobC = Int32 Function(
    Pointer<Void> stmt,
    Int32 index,
    Pointer<Uint8> value,
    Int32 length,
    Pointer<NativeFunction<Void Function(Pointer<Void>)>> destroy);
typedef _BindBlobD = int Function(
    Pointer<Void> stmt,
    int index,
    Pointer<Uint8> value,
    int length,
    Pointer<NativeFunction<Void Function(Pointer<Void>)>> destroy);

typedef _BindNullC = Int32 Function(Pointer<Void> stmt, Int32 index);
typedef _BindNullD = int Function(Pointer<Void> stmt, int index);

typedef _CountC = Int32 Function(Pointer<Void> stmt);
typedef _CountD = int Function(Pointer<Void> stmt);

typedef _NameC = Pointer<Utf8> Function(Pointer<Void> stmt, Int32 index);
typedef _NameD = Pointer<Utf8> Function(Pointer<Void> stmt, int index);

typedef _TypeC = Int32 Function(Pointer<Void> stmt, Int32 index);
typedef _TypeD = int Function(Pointer<Void> stmt, int index);

typedef _ColumnIntC = Int64 Function(Pointer<Void> stmt, Int32 index);
typedef _ColumnIntD = int Function(Pointer<Void> stmt, int index);

typedef _ColumnDoubleC = Double Function(Pointer<Void> stmt, Int32 index);
typedef _ColumnDoubleD = double Function(Pointer<Void> stmt, int index);

typedef _ColumnTextC = Pointer<Uint8> Function(Pointer<Void> stmt, Int32 index);
typedef _ColumnTextD = Pointer<Uint8> Function(Pointer<Void> stmt, int index);

typedef _ColumnBytesC = Int32 Function(Pointer<Void> stmt, Int32 index);
typedef _ColumnBytesD = int Function(Pointer<Void> stmt, int index);

typedef _ColumnBlobC = Pointer<Uint8> Function(Pointer<Void> stmt, Int32 index);
typedef _ColumnBlobD = Pointer<Uint8> Function(Pointer<Void> stmt, int index);

typedef _ErrMsgC = Pointer<Utf8> Function(Pointer<Void> db);
typedef _ErrMsgD = Pointer<Utf8> Function(Pointer<Void> db);

typedef _ChangesC = Int32 Function(Pointer<Void> db);
typedef _ChangesD = int Function(Pointer<Void> db);

typedef _RowIdC = Int64 Function(Pointer<Void> db);
typedef _RowIdD = int Function(Pointer<Void> db);

typedef _BusyC = Int32 Function(Pointer<Void> db, Int32 ms);
typedef _BusyD = int Function(Pointer<Void> db, int ms);

/// A row, column name to value. Values are `int`, `double`, `String`, `Uint8List`
/// or null — the four shapes sqlite actually stores, so callers never see a
/// `dynamic` they have to probe.
typedef SqlRow = Map<String, Object?>;

/// What a DAO needs from a connection: one statement in, rows out. `DataDatabase`
/// implements it; tests implement it with a fixed list of rows, so the mapping
/// logic can be exercised without a database file.
abstract class Queryable {
  List<SqlRow> query(String sql, [List<Object?> params]);
}

/// Raised for anything sqlite reports as a failure, carrying the statement that
/// caused it: the message alone (`no such column: foo`) does not say which query
/// ran, and this layer has no other way to name it.
class SqliteException implements Exception {
  SqliteException(this.message, this.sql);

  final String message;
  final String sql;

  @override
  String toString() => 'SqliteException: $message\n  in: $sql';
}

/// One open connection. Not thread-safe by contract, but opened FULLMUTEX so an
/// accidental overlap degrades to a lock rather than memory corruption.
class SqliteDatabase {
  SqliteDatabase._(this._lib, this._db, this.path);

  final Sqlite _lib;
  final Pointer<Void> _db;

  /// The file this connection holds open, for error messages and diagnostics.
  final String path;

  bool _closed = false;

  /// Rows of [sql], with [params] bound positionally. Every value the caller
  /// passes is copied by sqlite (`SQLITE_TRANSIENT`), so a temporary allocation
  /// is safe to free as soon as this returns.
  List<SqlRow> query(String sql, [List<Object?> params = const []]) {
    final stmt = _prepare(sql);
    try {
      _bind(stmt, params);
      final rows = <SqlRow>[];
      final count = _lib._columnCount(stmt);
      final names = List<String>.generate(count, (i) => _columnName(stmt, i));
      while (true) {
        final rc = _lib._step(stmt);
        if (rc == _done) break;
        if (rc != _row) throw SqliteException(_lib._error(_db), sql);
        final row = <String, Object?>{};
        for (var i = 0; i < count; i++) {
          row[names[i]] = _readColumn(stmt, i);
        }
        rows.add(row);
      }
      return rows;
    } finally {
      _lib._finalize(stmt);
    }
  }

  /// Runs [sql] and returns the number of rows it changed, which is what an
  /// UPDATE or DELETE call site actually wants to know.
  int execute(String sql, [List<Object?> params = const []]) {
    final stmt = _prepare(sql);
    try {
      _bind(stmt, params);
      while (true) {
        final rc = _lib._step(stmt);
        if (rc == _done) break;
        if (rc != _row) throw SqliteException(_lib._error(_db), sql);
      }
      return _lib._changes(_db);
    } finally {
      _lib._finalize(stmt);
    }
  }

  /// The rowid of the last successful INSERT.
  int get lastInsertRowId => _lib._lastRowId(_db);

  /// Closes the connection. Idempotent: a second call is a no-op, so a shutdown
  /// path and a scope guard can both run.
  void close() {
    if (_closed) return;
    _closed = true;
    _lib._close(_db);
  }

  // --- internals ------------------------------------------------------------

  Pointer<Void> _prepare(String sql) {
    final native = sql.toNativeUtf8();
    final out = calloc<Pointer<Void>>();
    try {
      final rc = _lib._prepare(_db, native, -1, out, nullptr);
      if (rc != _ok) throw SqliteException(_lib._error(_db), sql);
      return out.value;
    } finally {
      calloc.free(out);
      calloc.free(native);
    }
  }

  void _bind(Pointer<Void> stmt, List<Object?> params) {
    for (var i = 0; i < params.length; i++) {
      final index = i + 1;
      final value = params[i];
      final int rc;
      if (value == null) {
        rc = _lib._bindNull(stmt, index);
      } else if (value is bool) {
        // Before int: Dart keeps them distinct, and Room stores booleans as 0/1.
        rc = _lib._bindInt(stmt, index, value ? 1 : 0);
      } else if (value is int) {
        rc = _lib._bindInt(stmt, index, value);
      } else if (value is double) {
        rc = _lib._bindDouble(stmt, index, value);
      } else if (value is String) {
        rc = _bindText(stmt, index, value);
      } else if (value is Uint8List) {
        rc = _bindBlob(stmt, index, value);
      } else {
        throw ArgumentError.value(value, 'params[$i]', 'unsupported bind type');
      }
      if (rc != _ok) throw SqliteException(_lib._error(_db), 'bind #$index');
    }
  }

  int _bindText(Pointer<Void> stmt, int index, String value) {
    final native = value.toNativeUtf8();
    try {
      return _lib._bindText(stmt, index, native, -1, _transient);
    } finally {
      calloc.free(native);
    }
  }

  int _bindBlob(Pointer<Void> stmt, int index, Uint8List value) {
    final native = calloc<Uint8>(value.length);
    try {
      native.asTypedList(value.length).setAll(0, value);
      return _lib._bindBlob(stmt, index, native, value.length, _transient);
    } finally {
      calloc.free(native);
    }
  }

  Object? _readColumn(Pointer<Void> stmt, int index) {
    switch (_lib._columnType(stmt, index)) {
      case _typeInteger:
        return _lib._columnInt(stmt, index);
      case _typeFloat:
        return _lib._columnDouble(stmt, index);
      case _typeText:
        return _columnText(stmt, index);
      case _typeBlob:
        return _readBlob(stmt, index);
      default:
        return null;
    }
  }

  /// A null-terminated UTF-8 pointer to a Dart string. [length] is only passed
  /// when the buffer is known not to be terminated (column text always is).
  String _text(Pointer<Utf8> ptr, [int? length]) {
    if (ptr == nullptr) return '';
    return ptr.toDartString(length: length);
  }

  String _columnName(Pointer<Void> stmt, int index) =>
      _text(_lib._columnName(stmt, index));

  String _columnText(Pointer<Void> stmt, int index) => _text(
      _lib._columnText(stmt, index).cast<Utf8>(),
      _lib._columnBytes(stmt, index));

  Uint8List _readBlob(Pointer<Void> stmt, int index) {
    final length = _lib._columnBytes(stmt, index);
    final ptr = _lib._columnBlob(stmt, index);
    if (ptr == nullptr || length <= 0) return Uint8List(0);
    return Uint8List.fromList(ptr.asTypedList(length));
  }
}

/// The library itself. Loaded once per isolate; [open] returns null when the
/// platform has no usable libsqlite3, which the caller turns into "stay on the
/// channel" rather than a crash.
class Sqlite {
  Sqlite._(this._lib) {
    _open = _lib.lookupFunction<_OpenC, _OpenD>('sqlite3_open_v2');
    _close = _lib.lookupFunction<_CloseC, _CloseD>('sqlite3_close_v2');
    _prepare = _lib.lookupFunction<_PrepareC, _PrepareD>('sqlite3_prepare_v2');
    _step = _lib.lookupFunction<_StepC, _StepD>('sqlite3_step');
    _finalize = _lib.lookupFunction<_FinalizeC, _FinalizeD>('sqlite3_finalize');
    _bindInt = _lib.lookupFunction<_BindIntC, _BindIntD>('sqlite3_bind_int64');
    _bindDouble =
        _lib.lookupFunction<_BindDoubleC, _BindDoubleD>('sqlite3_bind_double');
    _bindText =
        _lib.lookupFunction<_BindTextC, _BindTextD>('sqlite3_bind_text');
    _bindBlob =
        _lib.lookupFunction<_BindBlobC, _BindBlobD>('sqlite3_bind_blob');
    _bindNull =
        _lib.lookupFunction<_BindNullC, _BindNullD>('sqlite3_bind_null');
    _columnCount =
        _lib.lookupFunction<_CountC, _CountD>('sqlite3_column_count');
    _columnName = _lib.lookupFunction<_NameC, _NameD>('sqlite3_column_name');
    _columnType = _lib.lookupFunction<_TypeC, _TypeD>('sqlite3_column_type');
    _columnInt =
        _lib.lookupFunction<_ColumnIntC, _ColumnIntD>('sqlite3_column_int64');
    _columnDouble = _lib.lookupFunction<_ColumnDoubleC, _ColumnDoubleD>(
        'sqlite3_column_double');
    _columnText =
        _lib.lookupFunction<_ColumnTextC, _ColumnTextD>('sqlite3_column_text');
    _columnBytes = _lib
        .lookupFunction<_ColumnBytesC, _ColumnBytesD>('sqlite3_column_bytes');
    _columnBlob =
        _lib.lookupFunction<_ColumnBlobC, _ColumnBlobD>('sqlite3_column_blob');
    _errmsg = _lib.lookupFunction<_ErrMsgC, _ErrMsgD>('sqlite3_errmsg');
    _changes = _lib.lookupFunction<_ChangesC, _ChangesD>('sqlite3_changes');
    _lastRowId =
        _lib.lookupFunction<_RowIdC, _RowIdD>('sqlite3_last_insert_rowid');
    _busyTimeout = _lib.lookupFunction<_BusyC, _BusyD>('sqlite3_busy_timeout');
  }

  final DynamicLibrary _lib;

  late final _OpenD _open;
  late final _CloseD _close;
  late final _PrepareD _prepare;
  late final _StepD _step;
  late final _FinalizeD _finalize;
  late final _BindIntD _bindInt;
  late final _BindDoubleD _bindDouble;
  late final _BindTextD _bindText;
  late final _BindBlobD _bindBlob;
  late final _BindNullD _bindNull;
  late final _CountD _columnCount;
  late final _NameD _columnName;
  late final _TypeD _columnType;
  late final _ColumnIntD _columnInt;
  late final _ColumnDoubleD _columnDouble;
  late final _ColumnTextD _columnText;
  late final _ColumnBytesD _columnBytes;
  late final _ColumnBlobD _columnBlob;
  late final _ErrMsgD _errmsg;
  late final _ChangesD _changes;
  late final _RowIdD _lastRowId;
  late final _BusyD _busyTimeout;

  static Sqlite? _instance;

  /// The library, or null when this platform cannot open it. Cached per isolate:
  /// `DynamicLibrary.open` on the same soname is cheap but not free, and the DAO
  /// asks once per call.
  static Sqlite? open() {
    final cached = _instance;
    if (cached != null) return cached;
    try {
      return _instance = Sqlite._(DynamicLibrary.open('libsqlite3.so'));
    } on ArgumentError {
      // No such soname on this platform (desktop test runs, mostly).
      return null;
    }
  }

  /// Opens [path]. [readOnly] is the safe default for a file another component
  /// owns: a reader that never writes cannot corrupt Room's journal, and every
  /// query still sees committed rows under WAL.
  SqliteDatabase? openDatabase(String path, {bool readOnly = false}) {
    final name = path.toNativeUtf8();
    final out = calloc<Pointer<Void>>();
    try {
      final flags = readOnly
          ? _openReadOnly | _openFullMutex
          : _openReadWrite | _openCreate | _openFullMutex;
      final rc = _open(name, out, flags, nullptr);
      if (rc != _ok) {
        if (out.value.address != 0) _close(out.value);
        return null;
      }
      // A writer that finds Room mid-transaction should wait rather than fail:
      // WAL allows one writer, and the other one is a user gesture, not a loop.
      _busyTimeout(out.value, 2000);
      return SqliteDatabase._(this, out.value, path);
    } finally {
      calloc.free(out);
      calloc.free(name);
    }
  }

  String _error(Pointer<Void> db) {
    final msg = _errmsg(db);
    return msg == nullptr ? 'unknown sqlite error' : msg.toDartString();
  }
}
