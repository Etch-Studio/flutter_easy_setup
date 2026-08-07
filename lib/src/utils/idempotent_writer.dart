import 'dart:io';

/// Writes [bytes] to [file] only when they differ from its current content,
/// creating parent directories as needed.
/// Returns 1 when written, 0 when the file was already up to date — callers
/// sum the results to report convergence.
int writeBytesIfChanged(File file, List<int> bytes) {
  if (file.existsSync()) {
    final existing = file.readAsBytesSync();
    if (existing.length == bytes.length) {
      var identical = true;
      for (var i = 0; i < bytes.length; i++) {
        if (existing[i] != bytes[i]) {
          identical = false;
          break;
        }
      }
      if (identical) return 0;
    }
  }
  file.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  return 1;
}

/// Writes [content] only when [file] does not exist yet, creating parent
/// directories as needed. Returns 1 when created, 0 when left alone.
///
/// For the design sources the user (or an AI skill) is expected to take
/// over — templates, SVGs, starter pages. easy_setup seeds them once and
/// never clobbers the edits.
int writeIfAbsent(File file, String content) {
  if (file.existsSync()) return 0;
  file.createSync(recursive: true);
  file.writeAsStringSync(content);
  return 1;
}
