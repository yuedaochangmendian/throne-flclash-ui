// The first table, read straight from Room's file.
//
// This is the vertical slice: one table, one read, no writes. It exists to prove
// the two things that could sink the whole approach — that libsqlite3 can be
// opened beside Room's own connection, and that the column names in `groups`
// are what the Kotlin entity says they are. Everything else (profiles, routes,
// settings) follows the same shape once this one is trusted on a device.
//
// The DAO takes a [Queryable] rather than a [DataDatabase] so the mapping can be
// tested without a database: the SQL is fixed text, and the thing worth testing
// is what it does with the rows it gets back.

import 'sqlite.dart';

/// A row of `groups` (ProxyGroup.kt), carrying only the columns the UI list and
/// the selection logic actually read. The rest of the table stays in the file:
/// mapping all twenty-two columns before anything uses them would be dead code
/// with a migration cost attached.
class GroupRow {
  const GroupRow({
    required this.id,
    required this.name,
    required this.url,
    required this.archive,
    required this.displayOrder,
    required this.routeId,
    required this.subLastUpdate,
  });

  final int id;
  final String name;

  /// Non-empty means the group is a subscription, not a manual collection.
  final String url;

  final bool archive;
  final int displayOrder;

  /// The routing profile this group connects with; -1 follows the global one.
  final int routeId;

  /// Epoch seconds of the last subscription fetch.
  final int subLastUpdate;

  bool get isSubscription => url.isNotEmpty;

  factory GroupRow.fromRow(SqlRow row) {
    return GroupRow(
      id: _int(row, 'id'),
      name: _string(row, 'name'),
      url: _string(row, 'url'),
      archive: _bool(row, 'archive'),
      displayOrder: _int(row, 'display_order'),
      routeId: _int(row, 'route_id', fallback: -1),
      subLastUpdate: _int(row, 'sub_last_update'),
    );
  }

  // Room stores booleans as INTEGER 0/1, and a column added by a migration can
  // still be null on a row written before it existed. Both cases collapse here
  // so no caller has to know which one it got.
  static int _int(SqlRow row, String column, {int fallback = 0}) {
    final value = row[column];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  static String _string(SqlRow row, String column) {
    final value = row[column];
    return value is String ? value : '';
  }

  static bool _bool(SqlRow row, String column) => _int(row, column) != 0;

  @override
  String toString() => 'GroupRow($id, $name, subscription: $isSubscription)';
}

/// Reads `groups`. Ordering matches `GroupRepo.all()`: display order first, id
/// as the tie-break, so a freshly created group cannot jump ahead of a pinned one.
class GroupsDao {
  const GroupsDao(this._db);

  final Queryable _db;

  static const _select = '''
SELECT id, name, url, archive, display_order, route_id, sub_last_update
FROM groups
ORDER BY display_order, id''';

  /// Every group, archived ones included — the UI filters those itself, and a
  /// DAO that hid rows would make "restore from archive" impossible to build.
  List<GroupRow> list() => _db.query(_select).map(GroupRow.fromRow).toList();

  /// The groups a subscription refresh may touch.
  List<GroupRow> subscriptions() =>
      list().where((group) => group.isSubscription).toList();

  /// One group, or null. Uses the primary key, so a duplicate name (issue #4's
  /// symptom on the profile side) cannot select the wrong row.
  GroupRow? byId(int id) {
    final rows = _db.query(
      'SELECT id, name, url, archive, display_order, route_id, sub_last_update '
      'FROM groups WHERE id = ? LIMIT 1',
      [id],
    );
    return rows.isEmpty ? null : GroupRow.fromRow(rows.first);
  }

  /// The group a profile belongs to, by name — the lookup `groups.select` does
  /// on the Kotlin side before it can resolve a tag to a profile id.
  GroupRow? byName(String name) {
    final rows = _db.query(
      'SELECT id, name, url, archive, display_order, route_id, sub_last_update '
      'FROM groups WHERE name = ? LIMIT 1',
      [name],
    );
    return rows.isEmpty ? null : GroupRow.fromRow(rows.first);
  }
}
