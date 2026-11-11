// The document store (ADR 0002, phase 2).
//
// Bettbox keeps profiles, routes and settings as JSON files under an app-private
// directory (`lib/common/path.dart` -> getProfilePath). This project kept them
// in Room v20, which the Go/Dart side cannot reach. Phase 2 moves the *read*
// source to JSON documents so phase 3 can serve them as actions.
//
// The host still owns the one migration that matters: only Kotlin can open
// Room. `RoomToJsonMigration.kt` writes the initial snapshot once, with an
// explicit id map; this class never invents ids and never deletes Room. Until
// the snapshot exists, reads return an empty, versioned document rather than
// throwing — the caller then falls back to the channel path.
//
// Writes are atomic: build the whole string in memory, write a sibling temp
// file, flush, then rename. A crash mid-write leaves the previous document
// intact; there is no partial-JSON state to recover from.

import 'dart:convert';
import 'dart:io';

import '../box.dart';
import '../core/platform_value.dart';

/// Bump when the document shape changes. The migration and the audit both
/// compare against this value; a newer file is refused rather than misread.
const documentStoreVersion = 1;

/// The seven Room v20 tables, dumped by column name. Keeping the table names as
/// the document names means the migration needs no field mapping at all: every
/// row is copied verbatim, including ids, JSON blobs and nulls.
const documentNames = <String>[
  'profiles',
  'groups',
  'route_profiles',
  'route_rules',
  'global_route_rules',
  'settings',
  'markers',
];

/// A snapshot is one named document's parsed content.
typedef Document = Map<String, Object?>;

/// Returns the storage directory for a `data.path` answer.
///
/// `data.path` gives the Room database file (`.../databases/sager_net.db`).
/// Documents live in a `documents/` sibling so a Room backup or a database
/// reset never sweeps them away.
String documentDirectoryOf(String databasePath) {
  final file = File(databasePath);
  return '${file.parent.path}${Platform.pathSeparator}documents';
}

/// Wraps raw rows in the versioned envelope the store writes.
///
/// Pure, so the shape (and the version guard) is testable without a file
/// system. Unknown keys are preserved: a newer field written by a later build
/// must survive a round-trip through this one.
Document documentEnvelope(String name, List<Object?> rows) => {
  'version': documentStoreVersion,
  'name': name,
  'rows': rows,
};

/// Reads one envelope, refusing anything that is not a version we understand.
///
/// Returns null for missing/corrupt/foreign documents so the caller can decide
/// (empty state, fallback, or re-run the migration) instead of catching a
/// FormatException in a widget build.
Document? parseDocument(Object? raw) {
  if (raw is String) {
    try {
      return _validated(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
  if (raw is Map) return _validated(Map<String, Object?>.from(raw));
  return null;
}

Document? _validated(Document value) {
  final version = (value['version'] as num?)?.toInt();
  if (version == null || version > documentStoreVersion) return null;
  final rows = value['rows'];
  if (rows is! List) return null;
  return value;
}

/// The rows of one document, or an empty list when it is absent/unreadable.
List<Object?> rowsOf(Document? document) {
  final rows = document?['rows'];
  return rows is List ? rows : const [];
}

/// One round-trip through the codec, for tests and for the migration's dry run.
Document? roundTrip(Document document) =>
    parseDocument(jsonEncode(document));

/// The file store. `directory` is injected so tests use a temp dir and the app
/// passes the `data.path`-derived directory.
class DocumentStore {
  const DocumentStore(this.directory);

  final String directory;

  File _file(String name) => File('$directory${Platform.pathSeparator}$name.json');

  /// True when every document exists and parses. Phase 3 uses this to decide
  /// whether the JSON source is authoritative or the channel fallback is.
  Future<bool> initialized() async {
    for (final name in documentNames) {
      if (await read(name) == null) return false;
    }
    return true;
  }

  Future<Document?> read(String name) async {
    final file = _file(name);
    try {
      if (!await file.exists()) return null;
      return parseDocument(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Atomically replaces one document.
  Future<void> write(String name, Document document) async {
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = _file(name);
    final temp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    final normalized = parseDocument(document);
    if (normalized == null) {
      throw ArgumentError('document $name has no version or rows');
    }
    await temp.writeAsString(jsonEncode(normalized), flush: true);
    await temp.rename(target.path);
  }

  /// Writes all documents in one pass. A failure leaves earlier files
  /// written but never a torn one; the caller can retry the whole migration.
  Future<void> writeAll(Map<String, Document> documents) async {
    for (final entry in documents.entries) {
      await write(entry.key, entry.value);
    }
  }

  /// One-time Room -> JSON migration, driven by the host's `data.documents`.
  ///
  /// Idempotent: it does nothing when the snapshot already exists, and a
  /// failed write can simply be retried. The host's export is read-only, so
  /// Room stays available as a fallback no matter what happens here.
  Future<bool> migrateFromRoom(BoxController box) async {
    if (await initialized()) return true;
    final raw = normalizePlatformValue(await box.dataDocuments());
    final json = raw is Map ? raw['json'] : null;
    if (json is! String) return false;
    final decoded = jsonDecode(json);
    if (decoded is! Map) return false;
    final documents = <String, Document>{};
    for (final name in documentNames) {
      final rows = decoded[name];
      if (rows is! List) return false;
      documents[name] = documentEnvelope(name, rows);
    }
    await writeAll(documents);
    return await initialized();
  }
}
