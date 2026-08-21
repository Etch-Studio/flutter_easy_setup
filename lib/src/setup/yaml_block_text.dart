import 'dart:io';

/// Line-based edits to a user-owned YAML file.
///
/// easy_setup.yaml belongs to the developer — their comments, their key
/// order, their indentation — so it is never re-serialized from a parsed
/// tree. Entries are inserted into the block that already holds them, at
/// the indentation the file already uses, and anything not line-addressable
/// (a flow-style `{...}` block) is reported with the text to paste instead
/// of being rewritten blindly. Same rule `capture` follows for
/// screenshots.yaml.
abstract final class YamlBlockText {
  /// Inserts [entries] into the block at [path] (`['admob', 'ad_units']`),
  /// creating the innermost block when it is missing.
  ///
  /// [entries] are the lines of one child each, already relative: their own
  /// indentation is preserved under the block's. Returns the new file text,
  /// or null when the path is not line-addressable — the caller reports it.
  static String? insert(
    String yaml,
    List<String> path,
    List<List<String>> entries,
  ) {
    if (entries.isEmpty) return yaml;
    // CRLF files are edited as CRLF files: splitting on \n alone leaves a \r
    // on every key, and then nothing matches.
    final newline = yaml.contains('\r\n') ? '\r\n' : '\n';
    final lines = yaml.split(RegExp(r'\r?\n'));

    var searchFrom = 0;
    var searchTo = lines.length;
    var parentIndent = '';
    String? indentStep;
    for (var depth = 0; depth < path.length; depth++) {
      final key = path[depth];
      final index = _indexOfKey(lines, key, parentIndent, searchFrom, searchTo);
      final isLast = depth == path.length - 1;
      if (index < 0) {
        // Only the innermost block is created; a missing parent means the
        // caller is looking at a file it does not understand.
        if (!isLast || depth == 0) return null;
        return _createBlock(
          lines,
          key,
          parentIndent,
          indentStep ?? _defaultStep(parentIndent),
          searchFrom,
          searchTo,
          entries,
        ).join(newline);
      }
      if (_isFlow(lines[index], key)) return null;
      // `key: {}` is an empty block written inline. Whether it is the block
      // being written to or a parent on the way down, it has to become a
      // real one first — children under a line that still says `{}` would
      // leave a file that no longer parses.
      lines[index] = '$parentIndent$key:';
      final blockEnd = _blockEnd(lines, index, parentIndent, searchTo);
      final childIndent = _childIndent(lines, index, blockEnd);
      if (childIndent != null && childIndent.length > parentIndent.length) {
        // What one level costs in this file, so a block created further down
        // matches a four-space document instead of assuming two.
        indentStep = childIndent.substring(parentIndent.length);
      }
      final step = indentStep ?? _defaultStep(parentIndent);
      if (isLast) {
        return _withInserted(
          lines,
          blockEnd,
          childIndent ?? '$parentIndent$step',
          entries,
        ).join(newline);
      }
      searchFrom = index + 1;
      searchTo = blockEnd;
      parentIndent = childIndent ?? '$parentIndent$step';
    }
    return null;
  }

  /// Index of `<indent><key>:` between [from] and [to], ignoring comments.
  static int _indexOfKey(
    List<String> lines,
    String key,
    String indent,
    int from,
    int to,
  ) {
    for (var i = from; i < to && i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('#')) continue;
      if (!line.startsWith('$indent$key:')) continue;
      // `admob:` must not match `admob_extra:`.
      final rest = line.substring('$indent$key:'.length);
      if (rest.isEmpty || rest.startsWith(' ') || rest.startsWith('\t')) {
        return i;
      }
    }
    return -1;
  }

  /// Whether `key:` carries an inline value that is not an empty map.
  static bool _isFlow(String line, String key) {
    final value = line.substring(line.indexOf('$key:') + key.length + 1).trim();
    if (value.isEmpty) return false;
    if (value.startsWith('#')) return false;
    return value != '{}';
  }

  /// First line after the block opened at [index] — the first non-blank
  /// line indented no deeper than the key itself.
  static int _blockEnd(
    List<String> lines,
    int index,
    String indent,
    int limit,
  ) {
    for (var i = index + 1; i < limit && i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      final leading = line.substring(0, line.length - line.trimLeft().length);
      if (leading.length <= indent.length) return i;
    }
    return limit < lines.length ? limit : lines.length;
  }

  /// The indentation the children of the block at [index] already use, or
  /// null when it has none yet.
  static String? _childIndent(List<String> lines, int index, int end) {
    for (var i = index + 1; i < end && i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final leading = line.substring(0, line.length - line.trimLeft().length);
      if (leading.isEmpty) return null;
      return leading;
    }
    return null;
  }

  /// One level of indentation for a file that has shown none yet.
  static String _defaultStep(String parentIndent) =>
      parentIndent.contains('\t') ? '\t' : '  ';

  static List<String> _createBlock(
    List<String> lines,
    String key,
    String indent,
    String step,
    int from,
    int to,
    List<List<String>> entries,
  ) {
    final at = _lastContent(lines, from, to) + 1;
    final childIndent = '$indent$step';
    return [...lines]..insertAll(at, [
      '$indent$key:',
      for (final entry in entries)
        for (final line in entry) '$childIndent$line',
    ]);
  }

  static List<String> _withInserted(
    List<String> lines,
    int blockEnd,
    String indent,
    List<List<String>> entries,
  ) {
    final at = _lastContent(lines, 0, blockEnd) + 1;
    return [...lines]..insertAll(at, [
      for (final entry in entries)
        for (final line in entry) '$indent$line',
    ]);
  }

  /// Index of the last non-blank line before [to] — new entries go after it
  /// rather than after any trailing blank lines the block is padded with.
  static int _lastContent(List<String> lines, int from, int to) {
    for (var i = (to < lines.length ? to : lines.length) - 1; i >= from; i--) {
      if (lines[i].trim().isNotEmpty) return i;
    }
    return from - 1;
  }

  /// [value] as a YAML scalar, quoted when it would otherwise not survive a
  /// round trip: `Banner #1` reads back as `Banner`, and a `:` can make the
  /// document invalid outright.
  static String scalar(String value) {
    final plain = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._()/+-]*$').hasMatch(value);
    if (plain && !value.endsWith(' ')) return value;
    return "'${value.replaceAll("'", "''")}'";
  }

  /// Applies [insert] to [file], returning false when the file is not
  /// line-addressable and the caller should print the block instead.
  static bool insertInFile(
    File file,
    List<String> path,
    List<List<String>> entries, {
    bool dryRun = false,
  }) {
    final updated = insert(file.readAsStringSync(), path, entries);
    if (updated == null) return false;
    if (!dryRun) file.writeAsStringSync(updated);
    return true;
  }
}
