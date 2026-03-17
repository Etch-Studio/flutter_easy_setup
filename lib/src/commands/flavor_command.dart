import 'dart:io';

import 'package:path/path.dart' as p;

import '../android/build_gradle_modifier.dart';
import '../exceptions.dart';
import '../firebase/firebase_copier.dart';
import '../ios/app_icon_generator.dart';
import '../ios/info_plist_modifier.dart';
import '../ios/info_plist_strings_generator.dart';
import '../ios/podfile_modifier.dart';
import '../ios/xcconfig_generator.dart';
import '../ios/xcodegen_generator.dart';
import '../ios/xcodegen_scripts_generator.dart';
import '../models/flavor_config.dart';
import '../utils/project_finder.dart';
import '../utils/xcodegen_runner.dart';

/// Command class that orchestrates the entire flavor setup pipeline.
///
/// Automatically configures Android and iOS settings in the following order:
///   1. Detect Flutter project root
///   2. Load and parse easy_setup.yaml
///   3. Android build.gradle — add productFlavors block (including signingConfigs)
///   3.5. Firebase — configure via FlutterFire CLI (downloads config files per flavor)
///   4. iOS xcconfig — generate Debug/Release/Profile config files per flavor
///   4.5. iOS App Icon — auto-generate app icons per flavor
///   5. iOS project.yml — generate XcodeGen configuration file
///   5.5. iOS scripts — generate XcodeGen build scripts
///   6. iOS xcodegen — run xcodegen generate (creates project.pbxproj + schemes)
///   7. iOS Info.plist — replace CFBundleDisplayName with variable
///   7.5. iOS InfoPlist.strings — app names + permission descriptions per locale
///   8. iOS Podfile — add build mode mapping per flavor
class FlavorCommand {
  /// Runs the flavor setup pipeline.
  ///
  /// If [projectRoot] is specified, skips auto-detection and uses the given path.
  /// If [dryRun] is true, prints a preview without modifying any files.
  static Future<void> run({bool dryRun = false, String? projectRoot}) async {
    // Step 1: Verify Flutter project root path
    final root = projectRoot ?? ProjectFinder.findFlutterRoot();
    if (root == null) {
      throw SetupException(
        'Could not find a Flutter project root.\n'
        'Run this command from inside a Flutter project directory.',
      );
    }
    print('Flutter project root: $root');

    // Step 2: Load easy_setup.yaml configuration file
    final configPath = ProjectFinder.configPath(root);
    print('Loading config from: $configPath');
    final config = EasySetupConfig.fromFile(configPath);
    if (config.flavors.isEmpty) {
      throw SetupException('No flavors defined in easy_setup.yaml');
    }
    print('Flavors: ${config.flavors.keys.join(', ')}');
    if (dryRun) print('\n[dry-run mode] No files will be written.');

    // Step 3: Android — insert flavorDimensions + productFlavors into build.gradle
    print('\n--- Android ---');
    final gradlePath = ProjectFinder.androidBuildGradlePath(root);
    BuildGradleModifier.modify(gradlePath, config.flavors, dryRun: dryRun);

    // Step 3.5: Firebase — configure via FlutterFire CLI
    final hasFirebase = config.flavors.values.any((f) => f.firebase != null);
    if (hasFirebase) {
      print('\n--- Firebase (FlutterFire CLI) ---');
      for (final entry in config.flavors.entries) {
        final firebase = entry.value.firebase;
        if (firebase != null) {
          await FirebaseConfigurator.configure(
            root,
            entry.key,
            firebase.projectId,
            entry.value.bundleId,
            dryRun: dryRun,
          );
        }
      }
    }

    // Step 4: iOS — generate xcconfig files
    print('\n--- iOS xcconfig ---');
    final xcconfigDir = ProjectFinder.iosXcconfigDir(root);

    // Clean up unused flavor xcconfig files
    XcconfigGenerator.cleanupUnusedXcconfigs(
      xcconfigDir,
      config.flavors.keys.toSet(),
      dryRun: dryRun,
    );

    for (final entry in config.flavors.entries) {
      XcconfigGenerator.generate(
        xcconfigDir,
        entry.key,
        entry.value,
        dryRun: dryRun,
      );
    }

    // Step 4.5: iOS — auto-generate app icons for flavors that have app_icon configured
    final assetCatalogDir = ProjectFinder.iosAssetCatalogDir(root);

    // Extract the list of currently configured flavors (those with app icons)
    final activeFlavorsWithIcon = <String>{};
    for (final entry in config.flavors.entries) {
      if (entry.value.appIcon != null) {
        activeFlavorsWithIcon.add(entry.key);
      }
    }

    // Clean up unused app icons (remove old icons when flavors change)
    if (activeFlavorsWithIcon.isNotEmpty ||
        Directory(assetCatalogDir).existsSync()) {
      AppIconGenerator.cleanupUnusedAppIcons(
        assetCatalogDir,
        activeFlavorsWithIcon,
        dryRun: dryRun,
      );
    }

    // Generate app icons for each flavor
    for (final entry in config.flavors.entries) {
      if (entry.value.appIcon != null) {
        print('\n--- iOS App Icon (${entry.key}) ---');
        AppIconGenerator.generate(
          root,
          assetCatalogDir,
          entry.key,
          entry.value.appIcon!,
          dryRun: dryRun,
        );
      }
    }

    // Step 5: iOS — modify Info.plist
    //        CFBundleDisplayName → $(APP_DISPLAY_NAME) + add permission keys
    print('\n--- iOS Info.plist ---');
    final plistPath = ProjectFinder.iosInfoPlistPath(root);
    InfoPlistModifier.modify(
      plistPath,
      permission: config.permission,
      dryRun: dryRun,
    );

    // Step 5.5: iOS — generate InfoPlist.strings
    //           flavor strings: ios/Flavors/{flavor}/{locale}.lproj/
    //           permission strings: ios/Runner/{locale}.lproj/
    //           must run before xcodegen generate so .lproj files are included in the project
    InfoPlistStringsGenerator.generate(
      root,
      flavors: config.flavors,
      permission: config.permission,
      localizedPermission: config.localizedPermission,
      dryRun: dryRun,
    );

    // Step 6: iOS — generate XcodeGen project.yml
    print('\n--- iOS project.yml (XcodeGen) ---');
    XcodeGenGenerator.generate(
      root,
      config.flavors,
      localizations: config.localizations,
      iosVersion: config.iosVersion,
      dryRun: dryRun,
    );

    // Step 6.5: iOS — generate XcodeGen build scripts
    print('\n--- iOS build scripts ---');
    final hasFlavorLocalized =
        config.flavors.values.any((f) => f.localized != null && f.localized!.isNotEmpty);
    XcodeGenScriptsGenerator.generate(
      root,
      hasFlavors: hasFlavorLocalized,
      dryRun: dryRun,
    );

    // Step 7: iOS — run xcodegen generate
    //        must run after all .lproj, xcconfig, etc. files are generated
    //        so they are correctly reflected in the Xcode project
    print('\n--- iOS xcodegen generate ---');
    XcodeGenRunner.run(root, dryRun: dryRun);

    // Step 8: iOS — add build mode mapping per flavor + permission macros to Podfile
    print('\n--- iOS Podfile ---');
    final podfilePath = ProjectFinder.iosPodfilePath(root);
    PodfileModifier.modify(
      podfilePath,
      config.flavors,
      permission: config.permission,
      iosVersion: config.iosVersion,
      dryRun: dryRun,
    );

    // Step 9: iOS — add easy_setup generated/managed files to .gitignore
    _updateGitignore(
      root,
      hasFlavorLocalized: hasFlavorLocalized,
      dryRun: dryRun,
    );

    // Print completion message
    _printSummary(dryRun: dryRun);
  }

  /// Adds easy_setup generated/managed files to ios/.gitignore.
  ///
  /// Gitignores xcodeproj generated by xcodegen generate, xcconfig/scripts/flavor
  /// strings generated by easy_setup, CocoaPods artifacts, etc.
  static void _updateGitignore(
    String projectRoot, {
    required bool hasFlavorLocalized,
    required bool dryRun,
  }) {
    final gitignorePath = p.join(projectRoot, 'ios', '.gitignore');
    final file = File(gitignorePath);
    String content = file.existsSync() ? file.readAsStringSync() : '';

    // If the easy_setup marker already exists, replace the entire block
    const marker = '# === easy_setup generated ===';
    const endMarker = '# === end easy_setup ===';

    final entries = <String>[
      '# Xcode project (generated by xcodegen)',
      'Runner.xcodeproj/',
      '',
      '# Xcode workspace + CocoaPods',
      'Runner.xcworkspace/',
      'Pods/',
      'Podfile.lock',
      '',
      '# easy_setup generated files',
      'project.yml',
      'xcodegen/',
      'Flavors/',
      'Flutter/Debug-*.xcconfig',
      'Flutter/Release-*.xcconfig',
      'Flutter/Profile-*.xcconfig',
      'Runner/Assets.xcassets/AppIcon-*/',
    ];

    if (hasFlavorLocalized) {
      entries.addAll([
        '',
        '# Modified by build script (flavor-specific display names)',
        'Runner/*.lproj/InfoPlist.strings',
      ]);
    }

    final block = '$marker\n${entries.join('\n')}\n$endMarker\n';

    // Replace existing block if found
    final blockPattern = RegExp(
      '${RegExp.escape(marker)}[\\s\\S]*?${RegExp.escape(endMarker)}\\n?',
    );

    if (blockPattern.hasMatch(content)) {
      final newContent = content.replaceFirst(blockPattern, block);
      if (newContent == content) return; // No changes

      if (dryRun) {
        print('  [dry-run] Would update ios/.gitignore');
        return;
      }

      file.writeAsStringSync(newContent);
      print('  Updated ios/.gitignore');
      return;
    }

    // Append if no existing block found
    if (dryRun) {
      print('  [dry-run] Would update ios/.gitignore');
      return;
    }

    if (content.isNotEmpty && !content.endsWith('\n')) {
      content += '\n';
    }
    content += '\n$block';

    file.writeAsStringSync(content);
    print('  Updated ios/.gitignore');
  }

  /// Prints a summary message and next steps after setup is complete.
  static void _printSummary({required bool dryRun}) {
    print('\n${dryRun ? "Preview" : "Setup"} complete!');
    if (!dryRun) {
      print('\nNext steps:');
      print('  1. flutter pub get');
      print('  2. cd ios && pod install');
      print('  3. flutter run --flavor <flavor> -t lib/main.dart');
    }
  }
}
