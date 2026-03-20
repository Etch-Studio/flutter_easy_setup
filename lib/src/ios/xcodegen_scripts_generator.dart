import 'dart:io';

import 'package:path/path.dart' as p;

/// A class that generates build script files referenced by XcodeGen.
///
/// Generates shell scripts that invoke Flutter's xcode_backend.sh:
///   - copy_flavor_strings.sh: copies the current flavor's InfoPlist.strings to Runner before build
///   - run_script.sh: runs the Flutter build before build
///   - thin_binary.sh: optimizes the binary after build
class XcodeGenScriptsGenerator {
  /// Generates the build script files.
  ///
  /// [projectRoot]: Flutter project root
  /// [hasFlavors]: only generates copy_flavor_strings.sh when flavors exist
  static void generate(
    String projectRoot, {
    bool hasFlavors = false,
    bool dryRun = false,
  }) {
    final scriptsDir = p.join(projectRoot, 'ios', 'xcodegen', 'script');

    if (hasFlavors) {
      _writeScript(
        p.join(scriptsDir, 'copy_flavor_strings.sh'),
        _copyFlavorStringsContent,
        dryRun: dryRun,
      );
    }

    _writeScript(
      p.join(scriptsDir, 'run_script.sh'),
      _runScriptContent,
      dryRun: dryRun,
    );

    _writeScript(
      p.join(scriptsDir, 'thin_binary.sh'),
      _thinBinaryContent,
      dryRun: dryRun,
    );
  }

  static void _writeScript(
    String path,
    String content, {
    required bool dryRun,
  }) {
    if (dryRun) {
      print('  · [dry-run] Would write: ${p.basename(path)}');
      return;
    }

    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);

    // Grant execute permission
    Process.runSync('chmod', ['+x', path]);
    print('  ✓ ${p.basename(path)}');
  }

  /// Script that extracts the flavor from the current build configuration and
  /// merges CFBundleDisplayName from Flavors/{flavor}/{locale}.lproj/InfoPlist.strings
  /// into Runner/{locale}.lproj/InfoPlist.strings.
  /// Runs before Copy Bundle Resources so Xcode naturally includes it in the bundle.
  static const _copyFlavorStringsContent = r'''#!/bin/sh

# Extract flavor from CONFIGURATION (e.g. "Debug-dev" → "dev", "Release-prod" → "prod")
FLAVOR=$(echo "$CONFIGURATION" | sed -n 's/^[^-]*-\(.*\)/\1/p')

if [ -z "$FLAVOR" ]; then
  echo "No flavor detected in configuration: $CONFIGURATION, skipping."
  exit 0
fi

FLAVORS_DIR="${SRCROOT}/Flavors/${FLAVOR}"

if [ ! -d "$FLAVORS_DIR" ]; then
  echo "Flavors directory not found: $FLAVORS_DIR, skipping."
  exit 0
fi

echo "Merging InfoPlist.strings for flavor: $FLAVOR"

for LPROJ in "$FLAVORS_DIR"/*.lproj; do
  if [ ! -d "$LPROJ" ]; then
    continue
  fi

  LOCALE=$(basename "$LPROJ")
  SRC_STRINGS="$LPROJ/InfoPlist.strings"
  DST_DIR="${SRCROOT}/Runner/${LOCALE}"
  DST_STRINGS="${DST_DIR}/InfoPlist.strings"

  if [ ! -f "$SRC_STRINGS" ]; then
    continue
  fi

  mkdir -p "$DST_DIR"

  if [ -f "$DST_STRINGS" ]; then
    # If Runner already has InfoPlist.strings (e.g., permissions)
    # remove the existing CFBundleDisplayName and replace with the flavor's value
    TEMP_FILE=$(mktemp)
    grep -v '"CFBundleDisplayName"' "$DST_STRINGS" > "$TEMP_FILE" || true
    grep '"CFBundleDisplayName"' "$SRC_STRINGS" >> "$TEMP_FILE" || true
    mv "$TEMP_FILE" "$DST_STRINGS"
  else
    cp "$SRC_STRINGS" "$DST_STRINGS"
  fi

  echo "  Merged: ${LOCALE}/InfoPlist.strings"
done
''';

  static const _runScriptContent = '''#!/bin/sh
/bin/sh "\$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh" build
''';

  static const _thinBinaryContent = '''#!/bin/sh
/bin/sh "\$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh" embed_and_thin
''';
}
