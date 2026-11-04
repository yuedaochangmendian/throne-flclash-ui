// Values that cross a PlatformChannel, an isolate SendPort or the Go message
// port do not keep the static shapes their producers declared.
//
// On Android, StandardMessageCodec decodes a Kotlin Map<*, *> into a runtime
// `_Map<Object?, Object?>`. Casting that straight to `Map<String, dynamic>` is
// a runtime failure:
//
//   type '_Map<Object?, Object?>' is not a subtype of type
//   'Map<String, dynamic>' in type cast
//
// `config.build` and `config.warpParams` used to do exactly that on every
// start / WARP registration. Fixing the two call sites alone is not enough:
// every nested map in a channel reply, every event on the EventChannel and
// every payload bounced through an isolate has the same shape. Normalize once
// at the boundary instead, recursively, so downstream code can keep using
// `Map<String, dynamic>` without defensive casts everywhere.

import 'dart:typed_data';

/// Rewrites an arbitrary platform value into a plain Dart tree whose maps are
/// always `Map<String, dynamic>` and whose lists are always `List<dynamic>`.
///
/// Typed data (`Uint8List` and friends, used for app icons) is passed through
/// untouched: it implements `List` but converting it to a growable list would
/// silently change the codec's wire type and break binary payloads.
Object? normalizePlatformValue(Object? value) {
  if (value is Map) {
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      out[entry.key.toString()] = normalizePlatformValue(entry.value);
    }
    return out;
  }
  if (value is TypedData) return value;
  if (value is List) {
    return value.map(normalizePlatformValue).toList(growable: false);
  }
  return value;
}

/// A checked version of `value as Map<String, dynamic>` for values that did
/// *not* go through [normalizePlatformValue]. Throws a readable error instead
/// of a bare type-cast exception when the wire shape changes.
Map<String, dynamic> asStringKeyedMap(Object? value, {String context = 'value'}) {
  final normalized = normalizePlatformValue(value);
  if (normalized is Map<String, dynamic>) return normalized;
  throw FormatException(
    '$context: expected a map, got ${value == null ? 'null' : value.runtimeType}',
  );
}

/// A checked list-of-maps helper for channel rows (`profiles`, `logs`, ...).
List<Map<String, dynamic>> asStringKeyedRows(Object? value, {String context = 'rows'}) {
  final normalized = normalizePlatformValue(value);
  if (normalized is! List) {
    throw FormatException(
      '$context: expected a list, got ${value == null ? 'null' : value.runtimeType}',
    );
  }
  return <Map<String, dynamic>>[
    for (final row in normalized)
      if (row is Map<String, dynamic>) row,
  ];
}
