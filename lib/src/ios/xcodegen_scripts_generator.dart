import 'dart:io';

import 'package:path/path.dart' as p;

/// A class that generates build script files referenced by XcodeGen.
///
/// Generates shell scripts that invoke Flutter's xcode_backend.sh:
///   - copy_firebase_plist.sh: copies GoogleService-Info.plist into the app bundle after build
///   - copy_flavor_strings.sh: copies the current flavor's InfoPlist.strings to Runner before build
///   - run_script.sh: runs the Flutter build before build
///   - thin_binary.sh: optimizes the binary after build
class XcodeGenScriptsGenerator {
  /// Generates the build script files.
  ///
  /// [projectRoot]: Flutter project root
  /// [hasFlavors]: only generates copy_flavor_strings.sh when flavors exist
  /// [firebaseFlavors]: generates copy_firebase_plist.sh with per-flavor branching when non-empty
  static void generate(
    String projectRoot, {
    bool hasFlavors = false,
    List<String> firebaseFlavors = const [],
    bool dryRun = false,
  }) {
    final scriptsDir = p.join(projectRoot, 'ios', 'xcodegen', 'script');

    if (firebaseFlavors.isNotEmpty) {
      _writeScript(
        p.join(scriptsDir, 'copy_firebase_plist.sh'),
        _buildCopyFirebasePlistContent(firebaseFlavors),
        dryRun: dryRun,
      );
    }

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

  /// Generates a script that copies the correct GoogleService-Info.plist into the app bundle.
  ///
  /// Runs after Copy Bundle Resources so the app bundle exists at copy time.
  /// Runner/Firebase/ is excluded from XcodeGen sources to prevent "Multiple commands produce"
  /// conflicts. Each flavor maps to its own subdirectory under Runner/Firebase/.
  static String _buildCopyFirebasePlistContent(List<String> flavors) {
    final sb = StringBuffer();
    sb.writeln('#!/bin/sh');
    sb.writeln();
    sb.writeln('# Copy the correct GoogleService-Info.plist based on build configuration.');
    sb.writeln('# Runs after Copy Bundle Resources so the app bundle exists.');
    sb.writeln();

    for (var i = 0; i < flavors.length; i++) {
      final flavor = flavors[i];
      final keyword = i == 0 ? 'if' : 'elif';
      sb.writeln('$keyword [[ "\$CONFIGURATION" == *"$flavor"* ]]; then');
      sb.writeln('    GOOGLESERVICE_INFO_FILE="$flavor/GoogleService-Info.plist"');
      sb.writeln();
    }

    final defaultFlavor = flavors.last;
    sb.writeln('else');
    sb.writeln('    echo "Warning: Unknown configuration \$CONFIGURATION, using default ($defaultFlavor)."');
    sb.writeln('    GOOGLESERVICE_INFO_FILE="$defaultFlavor/GoogleService-Info.plist"');
    sb.writeln('fi');
    sb.writeln();
    sb.writeln('SOURCE_PATH="\${PROJECT_DIR}/Runner/Firebase/\${GOOGLESERVICE_INFO_FILE}"');
    sb.writeln('DESTINATION_PATH="\${BUILT_PRODUCTS_DIR}/\${PRODUCT_NAME}.app/GoogleService-Info.plist"');
    sb.writeln();
    sb.writeln('if [ -f "\$SOURCE_PATH" ]; then');
    sb.writeln('    cp "\$SOURCE_PATH" "\$DESTINATION_PATH"');
    sb.writeln('    echo "Copied Firebase config: \${SOURCE_PATH} -> \${DESTINATION_PATH}"');
    sb.writeln('else');
    sb.writeln('    echo "Error: Firebase config not found: \${SOURCE_PATH}"');
    sb.writeln('    exit 1');
    sb.writeln('fi');

    return sb.toString();
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
