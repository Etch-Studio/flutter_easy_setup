import 'dart:convert';
import 'dart:io';

import '../exceptions.dart';

/// Merges values into a `--dart-define-from-file` JSON file, preserving
/// keys it does not own (idempotent).
class EnvJsonWriter {
  /// Merges [values] into the JSON map at [path]. Returns true when the file
  /// content changed.
  ///
  /// With [ownedPrefix], existing keys under that prefix that are absent
  /// from [values] are removed — so deleting an entry from easy_setup.yaml
  /// converges instead of leaving stale keys behind. Keys outside the
  /// prefix are always preserved.
  static bool merge(
    String path,
    Map<String, String> values, {
    bool dryRun = false,
    String? ownedPrefix,
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
      final stale = ownedPrefix != null &&
          key.startsWith(ownedPrefix) &&
          !values.containsKey(key);
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
