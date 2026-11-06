import 'dart:convert';
import 'dart:io';

/// Raised before a malformed config reaches the core.
class ConfigValidationError implements Exception {
  ConfigValidationError(this.message);
  final String message;
  @override
  String toString() => 'ConfigValidationError: $message';
}

/// First pass of Bettbox's double validation, adapted to sing-box profiles.
///
/// JSON-shaped configs are parsed here so a syntax error is reported by name
/// instead of surfacing later as a core failure. Non-JSON text (YAML overrides,
/// link lists) passes through untouched: only the Kotlin `ProfileValidator`
/// can judge those, and it remains the authoritative second check.
String validateConfigText(String content) {
  final trimmed = content.trimLeft();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      jsonDecode(content);
    } on FormatException catch (error) {
      throw ConfigValidationError('Invalid JSON: ${error.message}');
    }
  }
  return content;
}

/// Writes a config through a temporary file and only replaces the target once
/// validation has passed. Mirrors Bettbox's `Profile._writeFile`: a failed
/// validation or a failed rename never leaves a half-written profile behind.
class AtomicFileWriter {
  const AtomicFileWriter();

  Future<void> write(
    File target,
    String content, {
    String? Function(String value)? validate,
  }) async {
    final checked = validate?.call(content) ?? validateConfigText(content);
    final temp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await temp.parent.create(recursive: true);
    try {
      await temp.writeAsString(checked, flush: true);
      try {
        await temp.rename(target.path);
      } on FileSystemException {
        // Cross-device renames fail on some Android filesystems.
        await temp.copy(target.path);
      }
    } finally {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Best effort: the real config has already been replaced.
        }
      }
    }
  }
}

/// Commit/write/rollback guard for bridge calls that mutate a stored config.
///
/// The Kotlin side owns the file, so Dart cannot make the swap atomic; what it
/// can do is validate first, keep the previous content, and restore it when the
/// bridge rejects the new one. File-level atomicity is [AtomicFileWriter]'s job
/// once the write moves into Dart, or the Kotlin bridge's on the native side.
Future<T> guardedConfigWrite<T>({
  required Future<String> Function() readPrevious,
  required Future<T> Function(String content) commit,
  required Future<void> Function(String previous) restore,
  required String candidate,
  String? Function(String value)? validate,
}) async {
  final checked = validate?.call(candidate) ?? validateConfigText(candidate);
  String? previous;
  try {
    previous = await readPrevious();
  } catch (_) {
    // Without a known-good snapshot, a rollback would be more dangerous than
    // leaving the original content alone.
    previous = null;
  }
  try {
    return await commit(checked);
  } catch (_) {
    if (previous != null && previous.isNotEmpty) {
      try {
        await restore(previous);
      } catch (_) {
        // The original error is the useful one; never mask it with a restore failure.
      }
    }
    rethrow;
  }
}
