import 'dart:convert';
import 'dart:isolate';

/// Decodes a large JSON document off the UI isolate.
///
/// Bettbox moves group building, tracker parsing and log parsing to
/// `Isolate.run`. This module is the equivalent entry point for the editor and
/// import paths: a multi-megabyte subscription or config no longer stalls a
/// frame while `jsonDecode` walks it. Callers should keep the existing
/// synchronous `rows()` for small channel payloads — spawning an isolate costs
/// more than parsing those.
Future<Object?> decodeJsonInBackground(String source) =>
    Isolate.run<Object?>(() => jsonDecode(source));

/// Normalizes a decoded value on a worker isolate.
///
/// [transform] must be a top-level or static function so it can cross the
/// isolate boundary; it receives plain maps/lists, never widget objects.
Future<T> transformJsonInBackground<T>(String source, T Function(Object? value) transform) =>
    Isolate.run<T>(() => transform(jsonDecode(source)));
