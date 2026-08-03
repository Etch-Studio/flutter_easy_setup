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
