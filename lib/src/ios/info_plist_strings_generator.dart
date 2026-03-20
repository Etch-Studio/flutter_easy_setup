import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/flavor_config.dart';

/// A class that generates InfoPlist.strings files for each iOS locale.
///
/// Generates InfoPlist.strings in separate directories per flavor:
///   ios/Flavors/{flavor}/{locale}.lproj/InfoPlist.strings
///
/// During build, a build phase script copies the current flavor's strings
/// to the Runner directory so that Xcode can recognize them.
///
/// Permission strings are shared across all flavors, so they are
/// generated directly in Runner/{locale}.lproj/InfoPlist.strings.
class InfoPlistStringsGenerator {
  /// Generates the InfoPlist.strings files.
  ///
  /// [projectRoot]: Flutter project root
  /// [flavors]: full flavor configuration map
  /// [permission]: default iOS permission descriptions (written to en.lproj)
  /// [localizedPermission]: per-locale iOS permission descriptions
  static void generate(
    String projectRoot, {
    required Map<String, FlavorConfig> flavors,
    Map<String, String>? permission,
    Map<String, Map<String, String>>? localizedPermission,
    bool dryRun = false,
  }) {
    final hasBase = permission != null && permission.isNotEmpty;
    final hasLocalized =
        localizedPermission != null && localizedPermission.isNotEmpty;

    // Check if any flavor has localized app_name
    final hasFlavorLocalized =
        flavors.values.any((f) => f.localized != null && f.localized!.isNotEmpty);

    if (!hasBase && !hasLocalized && !hasFlavorLocalized) return;

    print('\n--- iOS InfoPlist.strings ---');

    // 1. Generate per-flavor InfoPlist.strings (ios/Flavors/{flavor}/{locale}.lproj/)
    if (hasFlavorLocalized) {
      _generateFlavorStrings(projectRoot, flavors, dryRun: dryRun);
    }

    // 2. Generate permission strings (ios/Runner/{locale}.lproj/)
    _generatePermissionStrings(
      projectRoot,
      permission: permission,
      localizedPermission: localizedPermission,
      dryRun: dryRun,
    );
  }

  /// Generates per-flavor InfoPlist.strings in ios/Flavors/{flavor}/{locale}.lproj/.
  static void _generateFlavorStrings(
    String projectRoot,
    Map<String, FlavorConfig> flavors, {
    required bool dryRun,
  }) {
    for (final entry in flavors.entries) {
      final flavor = entry.key;
      final config = entry.value;
      final localized = config.localized;
      if (localized == null || localized.isEmpty) continue;

      // Normalize localized keys to lowercase
      final normalizedLocalized = <String, FlavorLocalizedConfig>{
        for (final e in localized.entries) e.key.toLowerCase(): e.value,
      };

      // All locales + en (default), normalized to lowercase
      final locales = <String>{...normalizedLocalized.keys, 'en'};

      for (final locale in locales) {
        final entries = <String, String>{};

        if (locale == 'en') {
          // en uses the flavor's default name
          entries['CFBundleDisplayName'] = config.name;
        } else {
          final locConfig = normalizedLocalized[locale];
          if (locConfig?.appName != null) {
            entries['CFBundleDisplayName'] = locConfig!.appName!;
          }
        }

        if (entries.isEmpty) continue;

        _writeStringsFile(
          projectRoot,
          p.join('ios', 'Flavors', flavor, '$locale.lproj'),
          entries,
          dryRun: dryRun,
        );
      }
    }
  }

  /// Generates permission strings in ios/Runner/{locale}.lproj/.
  static void _generatePermissionStrings(
    String projectRoot, {
    Map<String, String>? permission,
    Map<String, Map<String, String>>? localizedPermission,
    required bool dryRun,
  }) {
    final hasBase = permission != null && permission.isNotEmpty;
    final hasLocalized =
        localizedPermission != null && localizedPermission.isNotEmpty;

    if (!hasBase && !hasLocalized) return;

    // Normalize localizedPermission keys to lowercase to avoid Xcode path issues
    final normalizedPermission = <String, Map<String, String>>{};
    if (hasLocalized) {
      for (final entry in localizedPermission.entries) {
        normalizedPermission[entry.key.toLowerCase()] = entry.value;
      }
    }

    // Collect all locales
    final allLocales = <String>{};
    if (hasLocalized) allLocales.addAll(normalizedPermission.keys);
    if (hasBase) allLocales.add('en');

    for (final locale in allLocales) {
      final entries = <String, String>{};

      // Include default permissions in the en locale
      if (locale == 'en' && hasBase) {
        entries.addAll(permission);
      }

      // Per-locale permissions
      final localePerms = normalizedPermission[locale];
      if (localePerms != null) {
        entries.addAll(localePerms);
      }

      if (entries.isEmpty) continue;

      _writeStringsFile(
        projectRoot,
        p.join('ios', 'Runner', '$locale.lproj'),
        entries,
        dryRun: dryRun,
      );
    }
  }

  /// Writes an InfoPlist.strings file.
  static void _writeStringsFile(
    String projectRoot,
    String relativeLprojDir,
    Map<String, String> entries, {
    required bool dryRun,
  }) {
    final lprojDir = p.join(projectRoot, relativeLprojDir);
    final stringsPath = p.join(lprojDir, 'InfoPlist.strings');

    if (dryRun) {
      print('  [dry-run] Would write: $stringsPath');
      return;
    }

    Directory(lprojDir).createSync(recursive: true);

    final sb = StringBuffer();
    for (final entry in entries.entries) {
      sb.writeln('"${entry.key}" = "${entry.value}";');
    }

    File(stringsPath).writeAsStringSync(sb.toString());
    print('  Wrote: $stringsPath');
  }
}
