import 'dart:io';

import '../exceptions.dart';
import '../models/flavor_config.dart';

/// A class that adds flavor configuration to Android's build.gradle(.kts) file.
///
/// Inserts flavorDimensions and productFlavors blocks right after the buildTypes block.
/// Supports both Groovy DSL (.gradle) and Kotlin DSL (.kts) syntax.
class BuildGradleModifier {
  /// Reads the build.gradle file and inserts flavor configuration.
  ///
  /// - Skips if the file does not exist (may not be an Android project).
  /// - If flavorDimensions already exists, removes the existing config and regenerates.
  /// - Finds the closing brace of the buildTypes block and inserts flavor config after it.
  static void modify(
    String gradlePath,
    Map<String, FlavorConfig> flavors, {
    bool hasFirebase = false,
    bool dryRun = false,
  }) {
    final file = File(gradlePath);
    if (!file.existsSync()) {
      print('  ─ build.gradle not found: $gradlePath');
      return;
    }

    var content = file.readAsStringSync();
    final isKts = gradlePath.endsWith('.kts');
    print('  · DSL: ${isKts ? "Kotlin (.kts)" : "Groovy (.gradle)"}');

    // Remove existing flavor config if present, then regenerate
    if (content.contains('flavorDimensions')) {
      print('  · existing flavorDimensions — stripping and regenerating...');
      content = _stripExistingFlavorConfig(content);
    }

    // Find the position of the buildTypes { ... } block
    final buildTypesMatch = RegExp(r'\bbuildTypes\s*\{').firstMatch(content);
    if (buildTypesMatch == null) {
      print('  ⚠ buildTypes block not found — skipping Android setup.');
      return;
    }

    // Find the matching closing brace from the opening brace position
    final openBrace = content.indexOf('{', buildTypesMatch.start);
    final blockEnd = _findBlockEnd(content, openBrace);
    if (blockEnd != -1) {
      print('  · buildTypes @ ${buildTypesMatch.start} → $blockEnd');
    }
    if (blockEnd == -1) {
      throw SetupException('Could not find end of buildTypes block in build.gradle');
    }

    // Insert signingConfigs block (if any flavor has signing config)
    final signingBlock = _buildSigningConfigsBlock(flavors, isKts);
    final hasSigningConfigsBlock = RegExp(r'\bsigningConfigs\s*\{').hasMatch(content);
    print('  · signingConfigs block: ${hasSigningConfigsBlock ? "exists" : "not found"}');
    if (signingBlock != null && !hasSigningConfigsBlock) {
      // Insert inside the android { block, before buildTypes
      content = '${content.substring(0, buildTypesMatch.start)}$signingBlock\n    ${content.substring(buildTypesMatch.start)}';
      // buildTypes position has shifted, so find it again
      final newBuildTypesMatch = RegExp(r'\bbuildTypes\s*\{').firstMatch(content)!;
      final newOpenBrace = content.indexOf('{', newBuildTypesMatch.start);
      final newBlockEnd = _findBlockEnd(content, newOpenBrace);
      if (newBlockEnd == -1) {
        throw SetupException('Could not find end of buildTypes block in build.gradle');
      }

      final flavorBlock = _buildFlavorBlock(flavors, isKts);
      content =
          '${content.substring(0, newBlockEnd + 1)}\n\n$flavorBlock${content.substring(newBlockEnd + 1)}';
    } else {
      // Insert flavor config block right after the buildTypes block
      final flavorBlock = _buildFlavorBlock(flavors, isKts);
      content =
          '${content.substring(0, blockEnd + 1)}\n\n$flavorBlock${content.substring(blockEnd + 1)}';
    }

    // Add Google Services plugin for Firebase if not already present
    if (hasFirebase) {
      content = _ensureGoogleServicesPlugin(content, isKts);
    }

    if (dryRun) {
      print('  · [dry-run] Would write: ${file.path}');
      return;
    }

    file.writeAsStringSync(content);
    print('  ✓ ${file.path}');

    // Also update settings.gradle(.kts) if Firebase is configured
    if (hasFirebase) {
      _ensureGoogleServicesInSettings(gradlePath, isKts, dryRun: dryRun);
    }
  }

  /// Ensures the Google Services plugin is present in the plugins block of build.gradle.
  static String _ensureGoogleServicesPlugin(String content, bool isKts) {
    if (content.contains('com.google.gms.google-services')) {
      print('  · google-services plugin: already present');
      return content;
    }

    // Find the plugins { ... } block and insert before the closing brace
    final pluginsMatch = RegExp(r'\bplugins\s*\{').firstMatch(content);
    if (pluginsMatch == null) {
      print('  ⚠ plugins block not found — cannot add google-services plugin');
      return content;
    }

    // Insert right after the opening line of plugins block
    final pluginLine = isKts
        ? '    id("com.google.gms.google-services")'
        : '    id "com.google.gms.google-services"';

    final openBrace = content.indexOf('{', pluginsMatch.start);
    final insertPos = content.indexOf('\n', openBrace) + 1;
    content = '${content.substring(0, insertPos)}$pluginLine\n${content.substring(insertPos)}';
    print('  · google-services plugin: added');
    return content;
  }

  /// Ensures the Google Services classpath is declared in settings.gradle(.kts).
  static void _ensureGoogleServicesInSettings(
    String buildGradlePath,
    bool isKts, {
    required bool dryRun,
  }) {
    // settings.gradle(.kts) is in the android root (parent of app/)
    final androidDir = File(buildGradlePath).parent.parent.path;
    final settingsName = isKts ? 'settings.gradle.kts' : 'settings.gradle';
    final settingsFile = File('$androidDir/$settingsName');

    if (!settingsFile.existsSync()) {
      print('  · $settingsName not found — skipping google-services dependency');
      return;
    }

    var content = settingsFile.readAsStringSync();
    if (content.contains('com.google.gms.google-services')) {
      print('  · $settingsName: google-services already declared');
      return;
    }

    // Find the plugins block in settings and add the dependency
    final pluginsMatch = RegExp(r'\bplugins\s*\{').firstMatch(content);
    if (pluginsMatch == null) {
      print('  ⚠ $settingsName: plugins block not found');
      return;
    }

    final pluginLine = isKts
        ? '    id("com.google.gms.google-services") version "4.4.2" apply false'
        : '    id "com.google.gms.google-services" version "4.4.2" apply false';

    final openBrace = content.indexOf('{', pluginsMatch.start);
    final closeBrace = _findBlockEnd(content, openBrace);
    if (closeBrace == -1) return;

    // Insert before the closing brace of plugins block
    var insertPos = closeBrace;
    while (insertPos > 0 && content[insertPos - 1] == ' ') {
      insertPos--;
    }
    content = '${content.substring(0, closeBrace)}    $pluginLine\n${content.substring(closeBrace)}';

    if (dryRun) {
      print('  · [dry-run] Would update $settingsName');
      return;
    }

    settingsFile.writeAsStringSync(content);
    print('  ✓ $settingsName: google-services dependency added');
  }

  // ---- Internal helper methods ----

  /// Tracks brace depth and returns the index of the matching closing brace.
  static int _findBlockEnd(String content, int openBraceIndex) {
    int depth = 0;
    for (int i = openBraceIndex; i < content.length; i++) {
      final ch = content[i];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// Removes existing flavor-related blocks (signingConfigs, flavorDimensions, productFlavors).
  static String _stripExistingFlavorConfig(String content) {
    // 1. Remove productFlavors { ... } block
    final pfMatch = RegExp(r'\bproductFlavors\s*\{').firstMatch(content);
    if (pfMatch != null) {
      final openBrace = content.indexOf('{', pfMatch.start);
      final blockEnd = _findBlockEnd(content, openBrace);
      if (blockEnd != -1) {
        var start = pfMatch.start;
        while (start > 0 && content[start - 1] != '\n') {
          start--;
        }
        var end = blockEnd + 1;
        if (end < content.length && content[end] == '\n') end++;
        content = content.substring(0, start) + content.substring(end);
      }
    }

    // 2. Remove flavorDimensions line
    content = content.replaceAll(RegExp(r'[ \t]*flavorDimensions[^\n]*\n'), '');

    // 3. Remove signingConfigs { ... } block
    final scMatch = RegExp(r'\bsigningConfigs\s*\{').firstMatch(content);
    if (scMatch != null) {
      final openBrace = content.indexOf('{', scMatch.start);
      final blockEnd = _findBlockEnd(content, openBrace);
      if (blockEnd != -1) {
        var start = scMatch.start;
        while (start > 0 && content[start - 1] != '\n') {
          start--;
        }
        var end = blockEnd + 1;
        if (end < content.length && content[end] == '\n') end++;
        content = content.substring(0, start) + content.substring(end);
      }
    }

    // Clean up consecutive blank lines
    content = content.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // Remove unnecessary blank lines before closing braces
    content = content.replaceAll(RegExp(r'\n{2,}(?=[ \t]*})'), '\n');

    return content;
  }

  /// Builds the signingConfigs block for flavors that have signing config.
  /// Returns null if no flavors have signing config.
  static String? _buildSigningConfigsBlock(
    Map<String, FlavorConfig> flavors,
    bool isKts,
  ) {
    final signingFlavors = flavors.entries
        .where((e) => e.value.signing != null)
        .toList();
    if (signingFlavors.isEmpty) return null;

    final sb = StringBuffer();
    if (isKts) {
      sb.writeln('    signingConfigs {');
      for (final entry in signingFlavors) {
        final flavor = entry.key;
        final signing = entry.value.signing!;
        sb.writeln('        create("$flavor") {');
        sb.writeln('            storeFile = file("${signing.keystore}")');
        sb.writeln('            keyAlias = "${signing.alias}"');
        sb.writeln('        }');
      }
      sb.writeln('    }');
    } else {
      sb.writeln('    signingConfigs {');
      for (final entry in signingFlavors) {
        final flavor = entry.key;
        final signing = entry.value.signing!;
        sb.writeln('        $flavor {');
        sb.writeln('            storeFile file("${signing.keystore}")');
        sb.writeln('            keyAlias "${signing.alias}"');
        sb.writeln('        }');
      }
      sb.writeln('    }');
    }
    return sb.toString();
  }

  /// Builds the Gradle code block for flavor configuration.
  ///
  /// If [isKts] is true, generates Kotlin DSL syntax; otherwise generates Groovy DSL syntax.
  static String _buildFlavorBlock(
    Map<String, FlavorConfig> flavors,
    bool isKts,
  ) {
    final sb = StringBuffer();
    if (isKts) {
      // Kotlin DSL syntax
      sb.writeln('    flavorDimensions += listOf("env")');
      sb.writeln('    productFlavors {');
      for (final entry in flavors.entries) {
        final flavor = entry.key;
        final config = entry.value;
        sb.writeln('        create("$flavor") {');
        sb.writeln('            dimension = "env"');
        sb.writeln('            applicationId = "${config.bundleId}"');
        sb.writeln('            resValue("string", "app_name", "${config.name}")');
        if (config.versionCode != null) {
          sb.writeln('            versionCode = ${config.versionCode}');
        }
        if (config.versionName != null) {
          sb.writeln('            versionName = "${config.versionName}"');
        }
        sb.writeln('            manifestPlaceholders += mapOf("appName" to "${config.name}")');
        if (config.signing != null) {
          sb.writeln('            signingConfig = signingConfigs.getByName("$flavor")');
        }
        sb.writeln('        }');
      }
      sb.writeln('    }');
    } else {
      // Groovy DSL syntax
      sb.writeln('    flavorDimensions "env"');
      sb.writeln('    productFlavors {');
      for (final entry in flavors.entries) {
        final flavor = entry.key;
        final config = entry.value;
        sb.writeln('        $flavor {');
        sb.writeln('            dimension "env"');
        sb.writeln('            applicationId "${config.bundleId}"');
        sb.writeln('            resValue "string", "app_name", "${config.name}"');
        if (config.versionCode != null) {
          sb.writeln('            versionCode ${config.versionCode}');
        }
        if (config.versionName != null) {
          sb.writeln('            versionName "${config.versionName}"');
        }
        sb.writeln('            manifestPlaceholders = [appName: "${config.name}"]');
        if (config.signing != null) {
          sb.writeln('            signingConfig signingConfigs.$flavor');
        }
        sb.writeln('        }');
      }
      sb.writeln('    }');
    }
    return sb.toString();
  }
}
