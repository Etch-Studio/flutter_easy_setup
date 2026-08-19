import 'dart:convert';
import 'dart:io';

import '../exceptions.dart';

/// Merges values into a `--dart-define-from-file` JSON file, preserving
/// keys it does not own (idempotent).
class EnvJsonWriter {
  /// Merges [values] into the JSON map at [path]. Returns true when the file
  /// content changed.
  ///
  /// [prunes] decides which *existing* keys the caller owns: an owned key
  /// that is absent from [values] is deleted, so dropping an entry from
  /// easy_setup.yaml converges instead of leaving a stale key behind.
  /// Everything else is preserved — including keys that merely share a
  /// prefix with the caller's own, and keys whose value this run could not
  /// resolve (an AdMob ID a failed lookup did not return, say), which must
  /// keep what they already have.
  static bool merge(
    String path,
    Map<String, String> values, {
    bool dryRun = false,
    bool Function(String key)? prunes,
  }) {
    final file = File(path);
    Map<String, Object?> current = {};
    if (file.existsSync()) {
      final text = file.readAsStringSync().trim();
      if (text.isNotEmpty) {
        final Object? decoded;
        try {
          decoded = json.decode(text);
        } on FormatException catch (e) {
          throw SetupException('$path is not valid JSON: ${e.message}');
        }
        if (decoded is! Map) {
          throw SetupException('$path must contain a JSON object.');
        }
        current = decoded.map((key, value) => MapEntry('$key', value));
      }
    }

    final merged = <String, Object?>{};
    current.forEach((key, value) {
      final stale =
          prunes != null && prunes(key) && !values.containsKey(key);
      if (!stale) merged[key] = value;
    });
    merged.addAll(values);

    final unchanged = file.existsSync() &&
        merged.length == current.length &&
        merged.entries.every((entry) => current[entry.key] == entry.value);
    if (unchanged) return false;

    if (!dryRun) {
      file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(merged)}\n');
    }
    return true;
  }
}
