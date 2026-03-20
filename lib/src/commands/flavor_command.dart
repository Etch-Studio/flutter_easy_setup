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
    print('[Step 1] Detecting Flutter project root...');
    final root = projectRoot ?? ProjectFinder.findFlutterRoot();
    if (root == null) {
      throw SetupException(
        'Could not find a Flutter project root.\n'
        'Run this command from inside a Flutter project directory.',
      );
    }
    print('Flutter project root: $root');

    // Step 2: Load easy_setup.yaml configuration file
    print('[Step 2] Loading easy_setup.yaml...');
    final configPath = ProjectFinder.configPath(root);
    print('Loading config from: $configPath');
    final config = EasySetupConfig.fromFile(configPath);
    if (config.flavors.isEmpty) {
      throw SetupException('No flavors defined in easy_setup.yaml');
    }
    print('Flavors: ${config.flavors.keys.join(', ')}');
    if (config.iosVersion != null) print('iOS version: ${config.iosVersion}');
    if (dryRun) print('\n[dry-run mode] No files will be written.');

    // Step 3: Android — insert flavorDimensions + productFlavors into build.gradle
    print('\n--- Android ---');
    print('[Step 3] Modifying Android build.gradle...');
    try {
      final gradlePath = ProjectFinder.androidBuildGradlePath(root);
      print('  build.gradle path: $gradlePath');
      BuildGradleModifier.modify(gradlePath, config.flavors, dryRun: dryRun);
      print('[Step 3] Done.');
    } catch (e, st) {
      print('[Step 3] FAILED: $e\n$st');
      rethrow;
    }

    // Step 3.5: Firebase — configure via FlutterFire CLI
    final hasFirebase = config.flavors.values.any((f) => f.firebase != null);
    if (hasFirebase) {
      print('\n--- Firebase (FlutterFire CLI) ---');
      print('[Step 3.5] Configuring Firebase per flavor...');
      for (final entry in config.flavors.entries) {
        final firebase = entry.value.firebase;
        if (firebase != null) {
          print('  Flavor: ${entry.key}, project_id: ${firebase.projectId}, bundle_id: ${entry.value.bundleId}');
          try {
            await FirebaseConfigurator.configure(
              root,
              entry.key,
              firebase.projectId,
              entry.value.bundleId,
              dryRun: dryRun,
            );
          } catch (e, st) {
            print('[Step 3.5] FAILED for flavor "${entry.key}": $e\n$st');
            rethrow;
          }
        }
      }
      print('[Step 3.5] Done.');
    } else {
      print('\n[Step 3.5] No firebase config found, skipping FlutterFire CLI.');
    }

    // Step 4: iOS — generate xcconfig files
    print('\n--- iOS xcconfig ---');
    print('[Step 4] Generating xcconfig files...');
    try {
      final xcconfigDir = ProjectFinder.iosXcconfigDir(root);
      print('  xcconfig dir: $xcconfigDir');

      XcconfigGenerator.cleanupUnusedXcconfigs(
        xcconfigDir,
        config.flavors.keys.toSet(),
        dryRun: dryRun,
      );

      for (final entry in config.flavors.entries) {
        print('  Generating xcconfig for flavor: ${entry.key}');
        XcconfigGenerator.generate(
          xcconfigDir,
          entry.key,
          entry.value,
          dryRun: dryRun,
        );
      }
      print('[Step 4] Done.');
    } catch (e, st) {
      print('[Step 4] FAILED: $e\n$st');
      rethrow;
    }

    // Step 4.5: iOS — auto-generate app icons for flavors that have app_icon configured
    print('[Step 4.5] Processing app icons...');
    try {
      final assetCatalogDir = ProjectFinder.iosAssetCatalogDir(root);
      print('  asset catalog dir: $assetCatalogDir');

      final activeFlavorsWithIcon = <String>{};
      for (final entry in config.flavors.entries) {
        if (entry.value.appIcon != null) {
          activeFlavorsWithIcon.add(entry.key);
        }
      }

      if (activeFlavorsWithIcon.isNotEmpty ||
          Directory(assetCatalogDir).existsSync()) {
        AppIconGenerator.cleanupUnusedAppIcons(
          assetCatalogDir,
          activeFlavorsWithIcon,
          dryRun: dryRun,
        );
      }

      for (final entry in config.flavors.entries) {
        if (entry.value.appIcon != null) {
          print('\n--- iOS App Icon (${entry.key}) ---');
          print('  source: ${entry.value.appIcon}');
          AppIconGenerator.generate(
            root,
            assetCatalogDir,
            entry.key,
            entry.value.appIcon!,
            dryRun: dryRun,
          );
        }
      }
      print('[Step 4.5] Done.');
    } catch (e, st) {
      print('[Step 4.5] FAILED: $e\n$st');
      rethrow;
    }

    // Step 5: iOS — modify Info.plist
    //        CFBundleDisplayName → $(APP_DISPLAY_NAME) + add permission keys
    print('\n--- iOS Info.plist ---');
    print('[Step 5] Modifying Info.plist...');
    try {
      final plistPath = ProjectFinder.iosInfoPlistPath(root);
      print('  Info.plist path: $plistPath');
      InfoPlistModifier.modify(
        plistPath,
        permission: config.permission,
        dryRun: dryRun,
      );
      print('[Step 5] Done.');
    } catch (e, st) {
      print('[Step 5] FAILED: $e\n$st');
      rethrow;
    }

    // Step 5.5: iOS — generate InfoPlist.strings
    //           flavor strings: ios/Flavors/{flavor}/{locale}.lproj/
    //           permission strings: ios/Runner/{locale}.lproj/
    //           must run before xcodegen generate so .lproj files are included in the project
    print('[Step 5.5] Generating InfoPlist.strings...');
    try {
      InfoPlistStringsGenerator.generate(
        root,
        flavors: config.flavors,
        permission: config.permission,
        localizedPermission: config.localizedPermission,
        dryRun: dryRun,
      );
      print('[Step 5.5] Done.');
    } catch (e, st) {
      print('[Step 5.5] FAILED: $e\n$st');
      rethrow;
    }

    // Step 6: iOS — generate XcodeGen project.yml
    print('\n--- iOS project.yml (XcodeGen) ---');
    print('[Step 6] Generating project.yml...');
    try {
      XcodeGenGenerator.generate(
        root,
        config.flavors,
        localizations: config.localizations,
        iosVersion: config.iosVersion,
        dryRun: dryRun,
      );
      print('[Step 6] Done.');
    } catch (e, st) {
      print('[Step 6] FAILED: $e\n$st');
      rethrow;
    }

    // Step 6.5: iOS — generate XcodeGen build scripts
    print('\n--- iOS build scripts ---');
    print('[Step 6.5] Generating build scripts...');
    try {
      final hasFlavorLocalized =
          config.flavors.values.any((f) => f.localized != null && f.localized!.isNotEmpty);
      print('  hasFlavorLocalized: $hasFlavorLocalized');
      XcodeGenScriptsGenerator.generate(
        root,
        hasFlavors: hasFlavorLocalized,
        dryRun: dryRun,
      );
      print('[Step 6.5] Done.');
    } catch (e, st) {
      print('[Step 6.5] FAILED: $e\n$st');
      rethrow;
    }

    // Step 7: iOS — run xcodegen generate
    //        must run after all .lproj, xcconfig, etc. files are generated
    //        so they are correctly reflected in the Xcode project
    print('\n--- iOS xcodegen generate ---');
    print('[Step 7] Running xcodegen generate...');
    try {
      XcodeGenRunner.run(root, dryRun: dryRun);
      print('[Step 7] Done.');
    } catch (e, st) {
      print('[Step 7] FAILED: $e\n$st');
      rethrow;
    }

    // Step 8: iOS — add build mode mapping per flavor + permission macros to Podfile
    print('\n--- iOS Podfile ---');
    print('[Step 8] Modifying Podfile...');
    try {
      final podfilePath = ProjectFinder.iosPodfilePath(root);
      print('  Podfile path: $podfilePath');
      PodfileModifier.modify(
        podfilePath,
        config.flavors,
        permission: config.permission,
        iosVersion: config.iosVersion,
        dryRun: dryRun,
      );
      print('[Step 8] Done.');
    } catch (e, st) {
      print('[Step 8] FAILED: $e\n$st');
      rethrow;
    }

    // Step 9: iOS — add easy_setup generated/managed files to .gitignore
    print('[Step 9] Updating ios/.gitignore...');
    try {
      final hasFlavorLocalized =
          config.flavors.values.any((f) => f.localized != null && f.localized!.isNotEmpty);
      _updateGitignore(
        root,
        hasFlavorLocalized: hasFlavorLocalized,
        dryRun: dryRun,
      );
      print('[Step 9] Done.');
    } catch (e, st) {
      print('[Step 9] FAILED: $e\n$st');
      rethrow;
    }

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
    print('  .gitignore path: $gitignorePath');
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
      if (newContent == content) {
        print('  ios/.gitignore already up to date.');
        return;
      }

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
