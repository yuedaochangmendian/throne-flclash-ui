// The route profile list, read straight from Room's file.
//
// This is a read-only reproduction of `BboxRoutes.list()`, not a rewrite of it:
// the screen consumes a fixed wire shape, so a fall back to `routes.list` has to
// be invisible. Keeping the SQL beside that shape is what makes the two answers
// comparable — if the host changes a column, this query fails (and the caller
// falls back) instead of quietly returning a different list.
//
// STATUS: WIRED for reads. `RouteProfilesSource` calls [RouteProfilesDao.listWire]
// and falls back to the channel on every failure. `groups` (GroupsDao) is still
// the un-wired vertical slice; `route_profiles` is the first live table.

import 'sqlite.dart';

/// `RuleType` ids for the four "simple address" rules, matching
/// `BboxRoutes.addressTypes` (RuleType.kt). Kept as a sorted list so the SQL
/// below and the count they produce cannot drift apart.
const simpleAddressRuleTypes = <int>[1, 2, 3, 10];

/// `SettingsRegistry.CURRENT_ROUTE_ID`'s default. The Kotlin side answers
/// `1L` when the row is missing or the stored value fails `{ it > 0 }`.
const defaultCurrentRouteId = 1;

/// One `route_profiles` row plus the two counts the list shows.
class RouteProfileRow {
  const RouteProfileRow({
    required this.id,
    required this.name,
    required this.isRemote,
    required this.isRaw,
    required this.ruleCount,
    required this.simpleRuleCount,
  });

  final int id;
  final String name;
  final bool isRemote;
  final bool isRaw;

  /// Every `route_rules` row of this profile. `RouteManager.load()` does not
  /// filter `disabled`, so neither does the count.
  final int ruleCount;

  /// The subset whose type is a simple address rule.
  final int simpleRuleCount;

  factory RouteProfileRow.fromRow(SqlRow row) => RouteProfileRow(
        id: _int(row, 'id'),
        name: _string(row, 'name'),
        isRemote: _bool(row, 'is_remote'),
        isRaw: _bool(row, 'is_raw'),
        ruleCount: _int(row, 'rule_count'),
        simpleRuleCount: _int(row, 'simple_rule_count'),
      );

  /// Exactly one entry of `routes.list`'s `profiles` array.
  Map<String, Object?> toWire(int currentId) => <String, Object?>{
        'id': id,
        'name': name,
        'current': id == currentId,
        'isRemote': isRemote,
        'isRaw': isRaw,
        'ruleCount': ruleCount,
        'simpleRuleCount': simpleRuleCount,
      };

  // Room stores booleans as INTEGER 0/1 and a column added by a migration can
  // still be null on an older row. Both collapse here so no caller has to know.
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

  /// `settings.value` is decimal text (SettingsStore.decodeLong). Accept the
  /// integer shape too, and treat a missing / unparsable / non-positive value as
  /// the registry default, exactly as `DataStore.currentRouteId` does.
  static int parseCurrentId(Object? value) {
    final int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num) {
      parsed = value.toInt();
    } else if (value is String) {
      parsed = int.tryParse(value.trim());
    } else {
      parsed = null;
    }
    return parsed != null && parsed > 0 ? parsed : defaultCurrentRouteId;
  }

  @override
  String toString() => 'RouteProfileRow($id, $name, $ruleCount rules)';
}

/// Reads `route_profiles`, its rules and the current selection from `settings`.
///
/// The DAO takes a [Queryable] rather than a [DataDatabase] so the mapping is
/// testable without a database — the same shape as [GroupsDao].
class RouteProfilesDao {
  const RouteProfilesDao(this._db);

  final Queryable _db;

  /// `RouteDao.allProfiles()` orders by id; `RouteManager.load()` groups every
  /// rule row by `route_profile_id` and counts all of them, including disabled
  /// ones. LEFT JOIN + COUNT on the join key reproduces both: a profile with no
  /// rules yields 0 rather than disappearing.
  static final _select = '''
SELECT p.id, p.name, p.is_remote, p.is_raw,
       COUNT(r.route_profile_id) AS rule_count,
       COALESCE(SUM(CASE WHEN r.type IN (${simpleAddressRuleTypes.join(', ')}) THEN 1 ELSE 0 END), 0) AS simple_rule_count
FROM route_profiles p
LEFT JOIN route_rules r ON r.route_profile_id = p.id
GROUP BY p.id, p.name, p.is_remote, p.is_raw
ORDER BY p.id''';

  static const _currentIdSelect =
      'SELECT value FROM settings WHERE key = ? LIMIT 1';

  List<RouteProfileRow> list() =>
      _db.query(_select).map(RouteProfileRow.fromRow).toList();

  int currentId() {
    final rows = _db.query(_currentIdSelect, ['current_route_id']);
    return rows.isEmpty
        ? defaultCurrentRouteId
        : RouteProfileRow.parseCurrentId(rows.first['value']);
  }

  /// The whole `routes.list` reply: `{currentId, profiles: [...]}`.
  Map<String, Object?> listWire() {
    final current = currentId();
    return <String, Object?>{
      'currentId': current,
      'profiles': list().map((row) => row.toWire(current)).toList(),
    };
  }
}
