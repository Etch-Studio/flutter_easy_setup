import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../exceptions.dart';
import 'setup_step.dart';

/// Idempotent, line-based edits to pubspec.yaml.
///
/// pubspec.yaml is a design source the developer owns, so nothing here
/// rewrites the file wholesale: dependencies are added by `flutter pub add`
/// (which resolves the version and touches only its own section), and tool
/// blocks are inserted or updated key by key, leaving comments, ordering and
/// indentation alone.
class PubspecText {
  /// Whether [package] is listed under `dependencies` or `dev_dependencies`.
  static bool hasDependency(String text, String package) {
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw SetupException('Could not parse pubspec.yaml: ${e.message}');
    }
    if (doc is! Map) return false;
    for (final section in ['dependencies', 'dev_dependencies']) {
      final node = doc[section];
      if (node is Map && node.containsKey(package)) return true;
    }
    return false;
  }

  /// Whether the file already declares a top-level `[key]:` block.
  static bool hasTopLevelBlock(String text, String key) => text
      .split('\n')
      .any((line) => RegExp('^$key:(\\s|\$)').hasMatch(line));

  /// Inserts a top-level `[key]:` block with [entries], or updates the
  /// entries it owns inside an existing one. Returns the new file text
  /// (identical to [text] when nothing had to change).
  ///
  /// Keys already in the block that are not in [entries] are left untouched —
  /// a developer's `upload_source_maps: true` survives. A **null** value in
  /// [entries] is the opposite: the caller owns that key and no longer wants
  /// it, so it is deleted when present (a self-hosted `url:` after the config
  /// moves back to the hosted service).
  static String ensureTopLevelBlock(
    String text,
    String key,
    Map<String, Object?> entries,
  ) {
    final wanted = <String, Object>{
      for (final entry in entries.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    final lines = text.split('\n');
    // Any top-level `key:` line, block or flow style — a flow-style one must
    // be found so it can be reported instead of duplicated below.
    final blockStart =
        lines.indexWhere((line) => RegExp('^$key:(\\s|\$)').hasMatch(line));

    if (blockStart < 0) {
      // Nothing to write and nothing to clean up.
      if (wanted.isEmpty) return text;
      final block = [
        '$key:',
        for (final entry in wanted.entries) '  ${entry.key}: ${entry.value}',
      ];
      // Keep exactly one blank line before the new block and one trailing
      // newline after it, whatever the file ended with.
      final body = text.trimRight();
      return '$body\n\n${block.join('\n')}\n';
    }

    // A flow-style block (`sentry: {org: x}`) cannot be edited line by line.
    // Trailing whitespace or a comment after the colon is not flow style.
    final inline =
        RegExp('^$key:\\s*(.*)\$').firstMatch(lines[blockStart])?.group(1)?.trim() ??
            '';
    if (inline.isNotEmpty && !inline.startsWith('#')) {
      throw SetupException(
        'pubspec.yaml declares `$key:` in flow style, which easy_setup will '
        'not rewrite. Replace it with:\n\n$key:\n'
        '${wanted.entries.map((e) => '  ${e.key}: ${e.value}').join('\n')}\n',
      );
    }

    // The block ends at the next non-blank, non-comment line at column 0.
    var blockEnd = lines.length;
    for (var i = blockStart + 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty || line.startsWith(' ') || line.startsWith('\t')) {
        continue;
      }
      if (line.startsWith('#')) continue;
      blockEnd = i;
      break;
    }

    final indent = _blockIndent(lines, blockStart, blockEnd);
    final updated = List.of(lines);
    // Insert after the last child line, not at blockEnd — trailing blank
    // lines and comments belong to whatever follows.
    var insertAt = blockStart + 1;
    for (var i = blockStart + 1; i < blockEnd; i++) {
      if (updated[i].trim().isNotEmpty) insertAt = i + 1;
    }

    for (final entry in entries.entries) {
      final pattern = RegExp('^$indent${entry.key}:\\s*(.*)\$');
      final existing = _indexWhereInRange(updated, blockStart + 1, blockEnd,
          (line) => pattern.hasMatch(line));
      if (entry.value == null) {
        if (existing >= 0) {
          updated.removeAt(existing);
          blockEnd--;
          if (insertAt > existing) insertAt--;
        }
        continue;
      }
      if (existing >= 0) {
        final line = '$indent${entry.key}: ${entry.value}';
        if (updated[existing] != line) updated[existing] = line;
      } else {
        updated.insert(insertAt, '$indent${entry.key}: ${entry.value}');
        insertAt++;
        blockEnd++;
      }
    }
    return updated.join('\n');
  }

  /// Indentation the block's children use (two spaces when it has none yet).
  static String _blockIndent(List<String> lines, int blockStart, int blockEnd) {
    for (var i = blockStart + 1; i < blockEnd; i++) {
      final match = RegExp(r'^([ \t]+)\S').firstMatch(lines[i]);
      if (match != null) return match.group(1)!;
    }
    return '  ';
  }

  static int _indexWhereInRange(
      List<String> lines, int start, int end, bool Function(String) test) {
    for (var i = start; i < end && i < lines.length; i++) {
      if (test(lines[i])) return i;
    }
    return -1;
  }
}

/// Adds [package] to pubspec.yaml with `flutter pub add` unless it is already
/// listed. Returns false when the dependency could not be added (no pubspec,
/// no flutter on PATH, or pub failed) — callers report it as a warning, since
/// the rest of their step still converged.
Future<bool> ensurePubDependency(
  SetupContext context,
  String package, {
  bool dev = false,
}) async {
  final pubspec = File(p.join(context.projectRoot, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    context.out.writeln('  ! No pubspec.yaml — skipped adding $package');
    return false;
  }
  if (PubspecText.hasDependency(pubspec.readAsStringSync(), package)) {
    context.out.writeln('  ✓ $package already in pubspec.yaml');
    return true;
  }
  final argument = dev ? 'dev:$package' : package;
  if (context.dryRun) {
    context.out.writeln('  [dry-run] Would run: flutter pub add $argument');
    return true;
  }
  if (await context.processes.which('flutter') == null) {
    context.out.writeln(
        '  ! flutter not found — add $package to pubspec.yaml yourself');
    return false;
  }
  context.out.writeln('  → flutter pub add $argument');
  final exitCode = await context.processes.stream(
    'flutter',
    ['pub', 'add', argument],
    workingDirectory: context.projectRoot,
  );
  if (exitCode != 0) {
    context.out.writeln(
        '  ! flutter pub add $argument failed (exit code $exitCode) — '
        'add it to pubspec.yaml yourself');
    return false;
  }
  context.out.writeln('  ✓ Added $package to pubspec.yaml');
  return true;
}
