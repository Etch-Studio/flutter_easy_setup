import 'dart:io';

/// A class that modifies the iOS Info.plist file.
///
/// 1. Changes the CFBundleDisplayName value to $(APP_DISPLAY_NAME)
/// 2. Adds permission map keys to Info.plist (only missing keys)
class InfoPlistModifier {
  /// Modifies the Info.plist file.
  ///
  /// [permission]: permission map from easy_setup.yaml (only keys are used to add to Info.plist)
  static void modify(
    String plistPath, {
    Map<String, String>? permission,
    bool dryRun = false,
  }) {
    final file = File(plistPath);
    if (!file.existsSync()) {
      print('  ⚠ Info.plist not found: $plistPath — skipping');
      return;
    }

    var content = file.readAsStringSync();

    // 1. CFBundleDisplayName → $(APP_DISPLAY_NAME)
    content = _setDisplayName(content);

    // 2. Add permission keys to Info.plist
    if (permission != null && permission.isNotEmpty) {
      content = _addPermissions(content, permission);
    }

    if (dryRun) {
      print('  · [dry-run] Would update Info.plist');
      return;
    }

    file.writeAsStringSync(content);
    print('  ✓ Info.plist updated');
  }

  /// Sets CFBundleDisplayName to $(APP_DISPLAY_NAME).
  static String _setDisplayName(String content) {
    final pattern = RegExp(
      r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)',
      dotAll: true,
    );

    if (pattern.hasMatch(content)) {
      print('  · CFBundleDisplayName found — updating');
      return content.replaceFirstMapped(pattern, (match) {
        return '${match.group(1)}\$(APP_DISPLAY_NAME)${match.group(2)}';
      });
    }

    // If CFBundleDisplayName doesn't exist, add it just before </dict>
    print('  · CFBundleDisplayName not found — adding');
    return content.replaceFirst(
      '</dict>\n</plist>',
      '\t<key>CFBundleDisplayName</key>\n'
      '\t<string>\$(APP_DISPLAY_NAME)</string>\n'
      '</dict>\n</plist>',
    );
  }

  /// Adds permission keys to Info.plist.
  /// Updates the value for keys that already exist, and adds new entries for missing keys.
  static String _addPermissions(
      String content, Map<String, String> permission) {
    final newEntries = StringBuffer();

    for (final entry in permission.entries) {
      final key = entry.key;
      final value = entry.value;

      final existingPattern = RegExp(
        '(<key>${RegExp.escape(key)}</key>\\s*<string>)[^<]*(</string>)',
        dotAll: true,
      );

      if (existingPattern.hasMatch(content)) {
        // Update value if already exists
        print('  · $key — updated');
        content = content.replaceFirstMapped(existingPattern, (match) {
          return '${match.group(1)}$value${match.group(2)}';
        });
      } else {
        // If not found, batch-add later
        print('  · $key — added');
        newEntries.writeln('\t<key>$key</key>');
        newEntries.writeln('\t<string>$value</string>');
      }
    }

    // Insert new entries just before </dict>
    final newContent = newEntries.toString();
    if (newContent.isNotEmpty) {
      content = content.replaceFirst(
        '</dict>\n</plist>',
        '$newContent</dict>\n</plist>',
      );
    }

    return content;
  }
}
