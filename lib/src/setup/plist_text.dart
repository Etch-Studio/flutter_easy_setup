import '../exceptions.dart';

/// Text-level helpers for editing XML plists without a plist dependency.
/// All functions preserve existing content and are meant for idempotent
/// setup steps.
///
/// Array operations are scoped to the array that is the key's immediate
/// value — a matching `<array>` elsewhere in the document is never touched.
abstract final class PlistText {
  /// Inserts [block] right before the final `</dict>` (the root dict close).
  static String insertBeforeFinalDictClose(String plist, String block) {
    final closeIndex = plist.lastIndexOf('</dict>');
    if (closeIndex < 0) {
      throw SetupException('Plist has no closing </dict> tag.');
    }
    return plist.substring(0, closeIndex) + block + plist.substring(closeIndex);
  }

  /// Returns the inner XML of the array that is the value of [key], `''`
  /// for the self-closing `<array/>` form, or null when the key is absent.
  /// Throws when the key's value is not an array.
  static String? arrayContent(String plist, String key) {
    final bounds = _arrayBounds(plist, key);
    if (bounds == null) return null;
    final (start, end, isEmpty) = bounds;
    return isEmpty ? '' : plist.substring(start, end);
  }

  /// Appends [entryXml] into the array that is the value of [key].
  /// The key must already exist — callers insert the full block themselves
  /// when it does not.
  static String appendToArray(String plist, String key, String entryXml) {
    final bounds = _arrayBounds(plist, key);
    if (bounds == null) {
      throw SetupException('Plist has no <key>$key</key>.');
    }
    final (start, end, isEmpty) = bounds;
    if (isEmpty) {
      // `start` and `end` delimit the whole `<array/>` tag in this case.
      return plist.replaceRange(start, end, '<array>\n$entryXml\t</array>');
    }
    return plist.replaceRange(start, start, '\n$entryXml\t');
  }

  /// Locates the array value of [key]: returns (contentStart, contentEnd,
  /// isEmptyForm). For the `<array/>` form the range covers the tag itself.
  static (int, int, bool)? _arrayBounds(String plist, String key) {
    final keyTag = '<key>$key</key>';
    final keyIndex = plist.indexOf(keyTag);
    if (keyIndex < 0) return null;
    final valueStart = keyIndex + keyTag.length;
    final tail = plist.substring(valueStart);

    final empty = RegExp(r'^\s*<array\s*/>').firstMatch(tail);
    if (empty != null) {
      final tagStart = valueStart + tail.indexOf('<array', empty.start);
      return (tagStart, valueStart + empty.end, true);
    }
    final open = RegExp(r'^\s*<array>').firstMatch(tail);
    if (open == null) {
      throw SetupException(
          'Plist value of <key>$key</key> is not an <array>.');
    }
    final contentStart = valueStart + open.end;
    final close = plist.indexOf('</array>', contentStart);
    if (close < 0) {
      throw SetupException('Plist <key>$key</key> array is not closed.');
    }
    return (contentStart, close, false);
  }
}
