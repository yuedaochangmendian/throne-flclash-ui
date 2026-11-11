// The mapping layer is the part worth testing without a database: the SQL is
// fixed text, and what can go wrong is how a row is turned into a model. Room
// writes booleans as 0/1, columns added by a migration are null on older rows,
// and a column that moved would still be read by name — none of those fail
// loudly, so each is pinned here.

import 'package:flrone/data/data_layer.dart';
import 'package:flrone/data/db.dart';
import 'package:flrone/data/groups_dao.dart';
import 'package:flrone/data/sqlite.dart';
import 'package:flutter_test/flutter_test.dart';

/// A connection that answers with fixed rows and remembers what it was asked.
class FakeDb implements Queryable {
  FakeDb(this.rows);

  final List<SqlRow> rows;
  final List<String> queries = [];
  final List<List<Object?>> params = [];

  @override
  List<SqlRow> query(String sql, [List<Object?> params = const []]) {
    queries.add(sql);
    this.params.add(params);
    return rows;
  }
}

void main() {
  group('GroupRow mapping', () {
    test('a complete row maps every field', () {
      final row = GroupRow.fromRow({
        'id': 7,
        'name': 'Tokyo',
        'url': 'https://example.test/sub',
        'archive': 0,
        'display_order': 3,
        'route_id': 2,
        'sub_last_update': 1700000000,
      });

      expect(row.id, 7);
      expect(row.name, 'Tokyo');
      expect(row.url, 'https://example.test/sub');
      expect(row.archive, isFalse);
      expect(row.displayOrder, 3);
      expect(row.routeId, 2);
      expect(row.subLastUpdate, 1700000000);
      expect(row.isSubscription, isTrue);
    });

    test('Room stores booleans as 0/1, and both survive', () {
      final archived = GroupRow.fromRow({'id': 1, 'archive': 1});
      final live = GroupRow.fromRow({'id': 2, 'archive': 0});

      expect(archived.archive, isTrue);
      expect(live.archive, isFalse);
    });

    test('a column a migration added is null on older rows', () {
      // route_id arrived in a later version; a row written before it is null and
      // must fall back to -1 (follow the global route) rather than 0 (a real id).
      final row = GroupRow.fromRow({'id': 1, 'name': 'old', 'route_id': null});

      expect(row.routeId, -1);
      expect(row.name, 'old');
    });

    test('a missing column does not throw', () {
      final row = GroupRow.fromRow({});

      expect(row.id, 0);
      expect(row.name, '');
      expect(row.url, '');
      expect(row.isSubscription, isFalse);
    });

    test('an empty url means a manual group, not a subscription', () {
      final row = GroupRow.fromRow({'id': 1, 'name': 'manual', 'url': ''});

      expect(row.isSubscription, isFalse);
    });
  });

  group('GroupsDao', () {
    test('list orders by display order then id', () {
      final db = FakeDb([]);
      GroupsDao(db).list();

      expect(db.queries.single, contains('ORDER BY display_order, id'));
      expect(db.queries.single, contains('FROM groups'));
    });

    test('list keeps archived groups; the UI decides what to show', () {
      final db = FakeDb([
        {'id': 1, 'name': 'live', 'archive': 0},
        {'id': 2, 'name': 'old', 'archive': 1},
      ]);

      final groups = GroupsDao(db).list();

      expect(groups, hasLength(2));
      expect(groups.last.archive, isTrue);
    });

    test('subscriptions filters on a non-empty url', () {
      final db = FakeDb([
        {'id': 1, 'name': 'manual', 'url': ''},
        {'id': 2, 'name': 'sub', 'url': 'https://example.test'},
      ]);

      final subscriptions = GroupsDao(db).subscriptions();

      expect(subscriptions, hasLength(1));
      expect(subscriptions.single.id, 2);
    });

    test('byId binds the primary key, so a duplicate name cannot match', () {
      final db = FakeDb([
        {'id': 9, 'name': 'Tokyo'},
      ]);
      final found = GroupsDao(db).byId(9);

      expect(db.queries.single, contains('WHERE id = ?'));
      expect(db.params.single, [9]);
      expect(found?.id, 9);
    });

    test('byName is the host lookup, not the recommended one', () {
      // `groups.select` resolves a tag to a profile id through the group's name,
      // which is why a duplicate name selects the wrong row (issue #4). The DAO
      // mirrors that shape so the port behaves the same; new call sites should
      // use byId.
      final db = FakeDb([
        {'id': 4, 'name': 'Same'},
      ]);

      final found = GroupsDao(db).byName('Same');

      expect(db.params.single, ['Same']);
      expect(found?.id, 4);
    });

    test('an empty result is null, not a thrown StateError', () {
      final db = FakeDb([]);

      expect(GroupsDao(db).byId(1), isNull);
    });
  });

  group('DatabaseLocation', () {
    test('a well-formed reply parses', () {
      final location = DatabaseLocation.parse({
        'path': '/data/data/x/databases/sager_net.db',
        'version': 19,
      });

      expect(location?.path, '/data/data/x/databases/sager_net.db');
      expect(location?.version, 19);
    });

    test('a reply without a path is null', () {
      expect(DatabaseLocation.parse({'version': 19}), isNull);
      expect(DatabaseLocation.parse({'path': ''}), isNull);
      expect(DatabaseLocation.parse(null), isNull);
      expect(DatabaseLocation.parse('nope'), isNull);
    });

    test('a reply without a version keeps the path and marks it unknown', () {
      final location = DatabaseLocation.parse({'path': '/tmp/x.db'});

      expect(location?.version, -1);
    });
  });

  group('schema gate', () {
    test(
        'the Dart constant matches the Room version this build was written for',
        () {
      // Bumping SagerDatabase's @Database(version = …) without this constant is
      // the one mistake that would make every query read the wrong column.
      expect(roomSchemaVersion, 20);
      expect(databaseFileName, 'sager_net.db');
    });
  });
}
