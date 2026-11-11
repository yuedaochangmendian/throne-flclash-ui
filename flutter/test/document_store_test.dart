// The document store's invariants (ADR 0002, phase 2).
//
// Room -> JSON is the one migration that can irreversibly lose user data, so
// the pure codec and the file behaviour are pinned here: a foreign version is
// refused, a corrupt file is not a thrown exception, a temp file never becomes
// a torn document, and an id written by Room survives the round-trip.

import 'dart:convert';
import 'dart:io';

import 'package:flrone/data/document_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('documentEnvelope / parseDocument', () {
    test('round-trips rows and unknown fields', () {
      final doc = documentEnvelope('profiles', [
        {'id': 7, 'name': 'Tokyo', 'outbound_json': '{"type":"vless"}'},
      ])..['future_field'] = 'keep me';

      final back = roundTrip(doc);

      expect(back, isNotNull);
      expect(back!['version'], documentStoreVersion);
      expect(back['name'], 'profiles');
      expect(back['future_field'], 'keep me');
      expect(rowsOf(back), hasLength(1));
      expect((rowsOf(back).first as Map)['id'], 7);
    });

    test('refuses a version written by a newer build', () {
      final doc = {...documentEnvelope('profiles', []), 'version': 999};
      expect(parseDocument(jsonEncode(doc)), isNull);
    });

    test('refuses a document without rows', () {
      expect(parseDocument('{"version":1,"name":"profiles"}'), isNull);
    });

    test('corrupt JSON and wrong types do not throw', () {
      expect(parseDocument('{not json'), isNull);
      expect(parseDocument('[]'), isNull);
      expect(parseDocument(42), isNull);
      expect(parseDocument(null), isNull);
      expect(rowsOf(null), isEmpty);
    });

    test('a document missing its version is refused', () {
      expect(parseDocument('{"name":"profiles","rows":[]}'), isNull);
    });
  });

  group('documentDirectoryOf', () {
    test('puts documents beside the Room database, not inside its file name', () {
      final dir = documentDirectoryOf('/data/data/com.x/databases/sager_net.db');
      expect(dir, contains('databases'));
      expect(dir, endsWith('documents'));
      expect(dir, isNot(contains('sager_net.db')));
    });
  });

  group('DocumentStore (real files)', () {
    late Directory temp;
    late DocumentStore store;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('document_store_test');
      store = DocumentStore(temp.path);
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('starts uninitialized', () async {
      expect(await store.initialized(), isFalse);
      expect(await store.read('profiles'), isNull);
    });

    test('atomic write leaves one file and no temp debris', () async {
      await store.write('profiles', documentEnvelope('profiles', [
        {'id': 1, 'name': 'A'},
        {'id': 2, 'name': null},
      ]));

      final files = temp.listSync();
      expect(files.where((f) => f.path.endsWith('.json')), hasLength(1));
      expect(files.where((f) => f.path.endsWith('.tmp')), isEmpty);

      final doc = await store.read('profiles');
      expect(rowsOf(doc), hasLength(2));
      // A null column is preserved, not silently turned into a missing field.
      expect((rowsOf(doc)[1] as Map).containsKey('name'), isTrue);
      expect((rowsOf(doc)[1] as Map)['name'], isNull);
    });

    test('a second write replaces the document', () async {
      await store.write('profiles', documentEnvelope('profiles', [{'id': 1}]));
      await store.write('profiles', documentEnvelope('profiles', [
        {'id': 1},
        {'id': 2},
      ]));

      expect(rowsOf(await store.read('profiles')), hasLength(2));
      expect(temp.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('a corrupt file reads as absent instead of throwing', () async {
      File('${temp.path}${Platform.pathSeparator}profiles.json')
          .writeAsStringSync('{broken');
      expect(await store.read('profiles'), isNull);
    });

    test('writeAll seeds all seven tables and initialized() turns true', () async {
      final docs = <String, Document>{
        for (final name in documentNames) name: documentEnvelope(name, []),
      };
      await store.writeAll(docs);

      expect(await store.initialized(), isTrue);
      for (final name in documentNames) {
        expect(await store.read(name), isNotNull, reason: name);
      }
    });

    test('initialized() is false when one of the seven is missing', () async {
      for (final name in documentNames.take(6)) {
        await store.write(name, documentEnvelope(name, []));
      }
      expect(await store.initialized(), isFalse);
    });

    test('write rejects an unversioned document', () async {
      expect(
        () => store.write('profiles', {'rows': []}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
