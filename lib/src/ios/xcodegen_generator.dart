import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/flavor_config.dart';

/// A class that generates the XcodeGen project.yml file.
///
/// Converts the flavor configuration from easy_setup.yaml into XcodeGen's
/// project.yml format, then uses the xcodegen generate command to generate
/// the entire Xcode project.
///
/// Replaces the previous pbxproj_modifier and scheme_generator.
class XcodeGenGenerator {
  /// Generates the project.yml file.
  ///
  /// [projectRoot]: Flutter project root
  /// [flavors]: flavor configuration map
  /// [localizations]: list of languages to register in knownRegions
  static void generate(
    String projectRoot,
    Map<String, FlavorConfig> flavors, {
    List<String>? localizations,
    String? iosVersion,
    bool dryRun = false,
  }) {
    final iosDir = p.join(projectRoot, 'ios');
    final projectYmlPath = p.join(iosDir, 'project.yml');

    final content = _buildProjectYml(flavors,
        localizations: localizations, iosVersion: iosVersion);

    if (dryRun) {
      print('  · [dry-run] Would write: project.yml');
      return;
    }

    Directory(iosDir).createSync(recursive: true);
    File(projectYmlPath).writeAsStringSync(content);
    print('  ✓ project.yml');
  }

  /// Builds the project.yml content.
  static String _buildProjectYml(
    Map<String, FlavorConfig> flavors, {
    List<String>? localizations,
    String? iosVersion,
  }) {
    final version = iosVersion ?? '13.0';
    final sb = StringBuffer();

    // name
    sb.writeln('name: Runner');
    sb.writeln();

    // options
    _writeOptions(sb, localizations: localizations, iosVersion: version);

    // configs
    _writeConfigs(sb, flavors);

    // settings (project-level)
    _writeProjectSettings(sb, iosVersion: version);

    // targets
    _writeTargets(sb, flavors);

    // schemes
    _writeSchemes(sb, flavors);

    return sb.toString();
  }

  /// Writes the options section.
  static void _writeOptions(StringBuffer sb,
      {List<String>? localizations, required String iosVersion}) {
    sb.writeln('options:');
    sb.writeln('  bundleIdPrefix: ""');
    sb.writeln('  deploymentTarget:');
    sb.writeln('    iOS: "$iosVersion"');

    if (localizations != null && localizations.isNotEmpty) {
      sb.writeln('  developmentLanguage: en');
      sb.writeln('  knownRegions:');
      sb.writeln('    - Base');
      for (final locale in localizations) {
        sb.writeln('    - $locale');
      }
    }

    sb.writeln();
  }

  /// Writes the configs section.
  ///
  /// Generates 3 configurations per flavor (Debug, Release, Profile).
  /// Profile is set to none type to prevent XcodeGen's default settings.
  static void _writeConfigs(StringBuffer sb, Map<String, FlavorConfig> flavors) {
    sb.writeln('configs:');
    for (final flavor in flavors.keys) {
      sb.writeln('  Debug-$flavor: debug');
      sb.writeln('  Profile-$flavor: none');
      sb.writeln('  Release-$flavor: release');
    }
    sb.writeln();
  }

  /// Writes the project-level settings section.
  static void _writeProjectSettings(StringBuffer sb,
      {required String iosVersion}) {
    sb.writeln('settings:');
    sb.writeln('  base:');
    sb.writeln('    ALWAYS_SEARCH_USER_PATHS: NO');
    sb.writeln('    CLANG_ANALYZER_NONNULL: YES');
    sb.writeln('    CLANG_CXX_LANGUAGE_STANDARD: "gnu++0x"');
    sb.writeln('    CLANG_ENABLE_MODULES: YES');
    sb.writeln('    CLANG_ENABLE_OBJC_ARC: YES');
    sb.writeln('    CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING: YES');
    sb.writeln('    CLANG_WARN_BOOL_CONVERSION: YES');
    sb.writeln('    CLANG_WARN_COMMA: YES');
    sb.writeln('    CLANG_WARN_CONSTANT_CONVERSION: YES');
    sb.writeln('    CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS: YES');
    sb.writeln('    CLANG_WARN_DIRECT_OBJC_ISA_USAGE: YES_ERROR');
    sb.writeln('    CLANG_WARN_EMPTY_BODY: YES');
    sb.writeln('    CLANG_WARN_ENUM_CONVERSION: YES');
    sb.writeln('    CLANG_WARN_INFINITE_RECURSION: YES');
    sb.writeln('    CLANG_WARN_INT_CONVERSION: YES');
    sb.writeln('    CLANG_WARN_NON_LITERAL_NULL_CONVERSION: YES');
    sb.writeln('    CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF: YES');
    sb.writeln('    CLANG_WARN_OBJC_LITERAL_CONVERSION: YES');
    sb.writeln('    CLANG_WARN_OBJC_ROOT_CLASS: YES_ERROR');
    sb.writeln('    CLANG_WARN_RANGE_LOOP_ANALYSIS: YES');
    sb.writeln('    CLANG_WARN_STRICT_PROTOTYPES: YES');
    sb.writeln('    CLANG_WARN_SUSPICIOUS_MOVE: YES');
    sb.writeln('    CLANG_WARN_UNREACHABLE_CODE: YES');
    sb.writeln('    CLANG_WARN__DUPLICATE_METHOD_MATCH: YES');
    sb.writeln('    ENABLE_STRICT_OBJC_MSGSEND: YES');
    sb.writeln('    ENABLE_TESTABILITY: YES');
    sb.writeln('    GCC_NO_COMMON_BLOCKS: YES');
    sb.writeln('    GCC_WARN_64_TO_32_BIT_CONVERSION: YES');
    sb.writeln('    GCC_WARN_ABOUT_RETURN_TYPE: YES_ERROR');
    sb.writeln('    GCC_WARN_UNDECLARED_SELECTOR: YES');
    sb.writeln('    GCC_WARN_UNINITIALIZED_AUTOS: YES_AGGRESSIVE');
    sb.writeln('    GCC_WARN_UNUSED_FUNCTION: YES');
    sb.writeln('    GCC_WARN_UNUSED_VARIABLE: YES');
    sb.writeln('    IPHONEOS_DEPLOYMENT_TARGET: "$iosVersion"');
    sb.writeln('    SDKROOT: iphoneos');
    sb.writeln();
  }

  /// Writes the targets section.
  static void _writeTargets(
      StringBuffer sb, Map<String, FlavorConfig> flavors) {
    sb.writeln('targets:');

    // Runner target
    _writeRunnerTarget(sb, flavors);

    // RunnerTests target
    _writeRunnerTestsTarget(sb);

    sb.writeln();
  }

  /// Writes the Runner target.
  static void _writeRunnerTarget(
      StringBuffer sb, Map<String, FlavorConfig> flavors) {
    sb.writeln('  Runner:');
    sb.writeln('    type: application');
    sb.writeln('    platform: iOS');
    sb.writeln();

    // configFiles
    sb.writeln('    configFiles:');
    for (final flavor in flavors.keys) {
      sb.writeln('      Debug-$flavor: Flutter/Debug-$flavor.xcconfig');
      sb.writeln('      Release-$flavor: Flutter/Release-$flavor.xcconfig');
      sb.writeln('      Profile-$flavor: Flutter/Profile-$flavor.xcconfig');
    }
    sb.writeln();

    // sources
    sb.writeln('    sources:');
    sb.writeln('      - path: Runner');
    sb.writeln('      - path: Flutter');
    sb.writeln();

    // preBuildScripts
    // Run Copy Flavor Strings first to merge per-flavor CFBundleDisplayName
    // into Runner/{locale}.lproj/
    // so that Copy Bundle Resources naturally includes them in the bundle
    final hasFlavorLocalized =
        flavors.values.any((f) => f.localized != null && f.localized!.isNotEmpty);

    sb.writeln('    preBuildScripts:');
    if (hasFlavorLocalized) {
      sb.writeln('      - name: Copy Flavor Strings');
      sb.writeln('        path: xcodegen/script/copy_flavor_strings.sh');
      sb.writeln('        basedOnDependencyAnalysis: false');
    }
    sb.writeln('      - name: Run Script');
    sb.writeln('        path: xcodegen/script/run_script.sh');
    sb.writeln('        basedOnDependencyAnalysis: false');
    sb.writeln();

    // postBuildScripts
    sb.writeln('    postBuildScripts:');
    sb.writeln('      - name: Thin Binary');
    sb.writeln('        path: xcodegen/script/thin_binary.sh');
    sb.writeln('        basedOnDependencyAnalysis: false');
    sb.writeln('        inputFiles:');
    sb.writeln(r'          - ${TARGET_BUILD_DIR}/${INFOPLIST_PATH}');
    sb.writeln();

    // settings
    sb.writeln('    settings:');
    sb.writeln('      base:');
    sb.writeln('        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon');
    sb.writeln('        ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS: "NO"');
    sb.writeln('        CLANG_ENABLE_MODULES: YES');
    sb.writeln('        CURRENT_PROJECT_VERSION: "\$(FLUTTER_BUILD_NUMBER)"');
    sb.writeln('        ENABLE_BITCODE: "NO"');
    sb.writeln('        INFOPLIST_FILE: Runner/Info.plist');
    sb.writeln('        PRODUCT_BUNDLE_IDENTIFIER: ""');
    sb.writeln('        PRODUCT_NAME: "\$(TARGET_NAME)"');
    sb.writeln(
        '        SWIFT_OBJC_BRIDGING_HEADER: Runner/Runner-Bridging-Header.h');
    sb.writeln('        SWIFT_VERSION: 5.0');
    sb.writeln('        VERSIONING_SYSTEM: apple-generic');
    sb.writeln('      configs:');

    // Per-flavor config settings
    for (final entry in flavors.entries) {
      final flavor = entry.key;
      final config = entry.value;

      for (final buildType in ['Debug', 'Release', 'Profile']) {
        sb.writeln('        $buildType-$flavor:');
        sb.writeln(
            '          PRODUCT_BUNDLE_IDENTIFIER: ${config.bundleId}');
        if (config.appIcon != null) {
          sb.writeln(
              '          ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon-$flavor');
        }
        if (buildType == 'Debug') {
          sb.writeln('          SWIFT_OPTIMIZATION_LEVEL: "-Onone"');
        }
      }
    }
    sb.writeln();
  }

  /// Writes the RunnerTests target.
  static void _writeRunnerTestsTarget(StringBuffer sb) {
    sb.writeln('  RunnerTests:');
    sb.writeln('    type: bundle.unit-test');
    sb.writeln('    platform: iOS');
    sb.writeln('    sources:');
    sb.writeln('      - path: RunnerTests');
    sb.writeln('    dependencies:');
    sb.writeln('      - target: Runner');
    sb.writeln('    settings:');
    sb.writeln('      base:');
    sb.writeln('        BUNDLE_LOADER: "\$(TEST_HOST)"');
    sb.writeln('        CODE_SIGN_STYLE: Automatic');
    sb.writeln('        CURRENT_PROJECT_VERSION: 1');
    sb.writeln('        GENERATE_INFOPLIST_FILE: YES');
    sb.writeln('        MARKETING_VERSION: 1.0');
    sb.writeln('        SWIFT_VERSION: 5.0');
    sb.writeln(
        '        TEST_HOST: "\$(BUILT_PRODUCTS_DIR)/Runner.app/\$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Runner"');
    sb.writeln();
  }

  /// Writes the schemes section.
  ///
  /// Only generates per-flavor schemes.
  /// Each flavor scheme maps to that flavor's Debug/Release/Profile configurations.
  static void _writeSchemes(
      StringBuffer sb, Map<String, FlavorConfig> flavors) {
    sb.writeln('schemes:');

    // Per-flavor schemes
    for (final flavor in flavors.keys) {
      sb.writeln('  $flavor:');
      sb.writeln('    build:');
      sb.writeln('      targets:');
      sb.writeln('        Runner: all');
      sb.writeln('    run:');
      sb.writeln('      config: Debug-$flavor');
      sb.writeln('    test:');
      sb.writeln('      config: Debug-$flavor');
      sb.writeln('    profile:');
      sb.writeln('      config: Profile-$flavor');
      sb.writeln('    analyze:');
      sb.writeln('      config: Debug-$flavor');
      sb.writeln('    archive:');
      sb.writeln('      config: Release-$flavor');
    }
  }
}
