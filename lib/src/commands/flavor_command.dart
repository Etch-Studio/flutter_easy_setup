import 'dart:io';

import 'package:path/path.dart' as p;

import '../android/build_gradle_modifier.dart';
import '../exceptions.dart';
import '../firebase/firebase_copier.dart';
import '../firebase/firebase_options_generator.dart';
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
///   4. iOS xcconfig — generate Debug/Release/Profile config files per flavor
///   5. iOS App Icon — auto-generate app icons per flavor
///   6. iOS Info.plist — replace CFBundleDisplayName with variable
///   7. iOS InfoPlist.strings — app names + permission descriptions per locale
///   8. iOS project.yml — generate XcodeGen configuration file
///   9. iOS scripts — generate XcodeGen build scripts
///  10. iOS xcodegen — run xcodegen generate (creates project.pbxproj + schemes)
///  11. Firebase — configure via FlutterFire CLI (requires Runner.xcodeproj from step 10)
///  12. iOS Podfile — add build mode mapping per flavor
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
    print('Config: $configPath');
    final config = EasySetupConfig.fromFile(configPath);
    if (config.flavors.isEmpty) {
      throw SetupException('No flavors defined in easy_setup.yaml');
    }
    print('Flavors: ${config.flavors.keys.join(', ')}');
    if (dryRun) print('\n[dry-run] No files will be written.\n');

    // Step 1: Android — insert flavorDimensions + productFlavors into build.gradle
    print('\n[1/11] Android');
    try {
      final gradlePath = ProjectFinder.androidBuildGradlePath(root);
      print('  · ${gradlePath.replaceFirst(root, '')}');
      BuildGradleModifier.modify(gradlePath, config.flavors, dryRun: dryRun);
      print('  ✓ Done');
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 2: iOS — generate xcconfig files
    print('\n[2/11] iOS xcconfig');
    try {
      final xcconfigDir = ProjectFinder.iosXcconfigDir(root);
      print('  · dir: ${xcconfigDir.replaceFirst(root, '')}');
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
      print('  ✓ Done');
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 3: iOS — auto-generate app icons
    print('\n[3/11] iOS App Icons');
    try {
      final assetCatalogDir = ProjectFinder.iosAssetCatalogDir(root);
      final activeFlavorsWithIcon = <String>{
        for (final e in config.flavors.entries)
          if (e.value.appIcon != null) e.key,
      };

      if (activeFlavorsWithIcon.isEmpty) {
        print('  ─ skipped (no app_icon configured)');
      } else {
        print('  · ${activeFlavorsWithIcon.length} flavor(s) with app icon');
        if (Directory(assetCatalogDir).existsSync()) {
          AppIconGenerator.cleanupUnusedAppIcons(
            assetCatalogDir,
            activeFlavorsWithIcon,
            dryRun: dryRun,
          );
        }
        for (final entry in config.flavors.entries) {
          if (entry.value.appIcon != null) {
            print('  · ${entry.key}: ${entry.value.appIcon}');
            AppIconGenerator.generate(
              root,
              assetCatalogDir,
              entry.key,
              entry.value.appIcon!,
              dryRun: dryRun,
            );
          }
        }
        print('  ✓ Done');
      }
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 4: iOS — modify Info.plist
    print('\n[4/11] iOS Info.plist');
    try {
      final plistPath = ProjectFinder.iosInfoPlistPath(root);
      print('  · ${plistPath.replaceFirst(root, '')}');
      InfoPlistModifier.modify(
        plistPath,
        permission: config.permission,
        dryRun: dryRun,
      );
      print('  ✓ Done');
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 5: iOS — generate InfoPlist.strings
    print('\n[5/11] iOS InfoPlist.strings');
    try {
      InfoPlistStringsGenerator.generate(
        root,
        flavors: config.flavors,
        permission: config.permission,
        localizedPermission: config.localizedPermission,
        dryRun: dryRun,
      );
      print('  ✓ Done');
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 6: iOS — generate XcodeGen project.yml
    print('\n[6/11] iOS project.yml (XcodeGen)');
    try {
      XcodeGenGenerator.generate(
        root,
        config.flavors,
        localizations: config.localizations,
        iosVersion: config.iosVersion,
        dryRun: dryRun,
      );
      print('  ✓ Done');
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 7: iOS — generate XcodeGen build scripts
    print('\n[7/11] iOS build scripts');
    try {
      final hasFlavorLocalized =
          config.flavors.values.any((f) => f.localized != null && f.localized!.isNotEmpty);
      print('  · flavor-localized: $hasFlavorLocalized');
      XcodeGenScriptsGenerator.generate(
        root,
        hasFlavors: hasFlavorLocalized,
        dryRun: dryRun,
      );
      print('  ✓ Done');
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 8: iOS — run xcodegen generate (creates Runner.xcodeproj/project.pbxproj)
    print('\n[8/11] xcodegen generate');
    try {
      XcodeGenRunner.run(root, dryRun: dryRun);
      print('  ✓ Done');
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 9: Firebase — configure via FlutterFire CLI
    // Must run after xcodegen (step 8) because flutterfire reads Runner.xcodeproj/project.pbxproj
    final hasFirebase = config.flavors.values.any((f) => f.firebase != null);
    if (!hasFirebase) {
      print('\n[9/11] Firebase  ─ skipped (no firebase config)');
    } else {
      print('\n[9/11] Firebase');
      for (final entry in config.flavors.entries) {
        final firebase = entry.value.firebase;
        if (firebase == null) continue;
        print('  · ${entry.key}  →  ${firebase.projectId} (${entry.value.bundleId})');
        try {
          await FirebaseConfigurator.configure(
            root,
            entry.key,
            firebase.projectId,
            entry.value.bundleId,
            dryRun: dryRun,
          );
        } catch (e, st) {
          print('  ✗ Failed [${entry.key}]: $e');
          print(st);
          rethrow;
        }
      }
      // Generate unified firebase_options.dart
      final firebaseFlavors = config.flavors.entries
          .where((e) => e.value.firebase != null)
          .map((e) => e.key)
          .toList();
      FirebaseOptionsGenerator.generate(root, firebaseFlavors, dryRun: dryRun);
      print('  ✓ Done');
    }

    // Step 10: iOS — add build mode mapping per flavor + permission macros to Podfile
    print('\n[10/11] iOS Podfile');
    try {
      final podfilePath = ProjectFinder.iosPodfilePath(root);
      print('  · ${podfilePath.replaceFirst(root, '')}');
      PodfileModifier.modify(
        podfilePath,
        config.flavors,
        permission: config.permission,
        iosVersion: config.iosVersion,
        dryRun: dryRun,
      );
      print('  ✓ Done');
    } catch (e, st) {
      print('  ✗ Failed: $e');
      print(st);
      rethrow;
    }

    // Step 11: iOS — add easy_setup generated/managed files to .gitignore
    try {
      final hasFlavorLocalized =
          config.flavors.values.any((f) => f.localized != null && f.localized!.isNotEmpty);
      _updateGitignore(
        root,
        hasFlavorLocalized: hasFlavorLocalized,
        dryRun: dryRun,
      );
    } catch (e, st) {
      print('  ✗ .gitignore update failed: $e');
      print(st);
      rethrow;
    }

    // Print completion message
    _printSummary(dryRun: dryRun);
  }

  /// Adds easy_setup generated/managed files to ios/.gitignore.
  static void _updateGitignore(
    String projectRoot, {
    required bool hasFlavorLocalized,
    required bool dryRun,
  }) {
    final gitignorePath = p.join(projectRoot, 'ios', '.gitignore');
    final file = File(gitignorePath);
    String content = file.existsSync() ? file.readAsStringSync() : '';

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

    final blockPattern = RegExp(
      '${RegExp.escape(marker)}[\\s\\S]*?${RegExp.escape(endMarker)}\\n?',
    );

    if (blockPattern.hasMatch(content)) {
      final newContent = content.replaceFirst(blockPattern, block);
      if (newContent == content) return;

      if (dryRun) {
        print('  · [dry-run] Would update ios/.gitignore');
        return;
      }

      file.writeAsStringSync(newContent);
      print('  ✓ ios/.gitignore updated');
      return;
    }

    if (dryRun) {
      print('  · [dry-run] Would update ios/.gitignore');
      return;
    }

    if (content.isNotEmpty && !content.endsWith('\n')) content += '\n';
    content += '\n$block';

    file.writeAsStringSync(content);
    print('  ✓ ios/.gitignore updated');
  }

  /// Prints a summary message and next steps after setup is complete.
  static void _printSummary({required bool dryRun}) {
    print('\n${dryRun ? "Preview" : "✓ Setup"} complete!');
    if (!dryRun) {
      print('\nNext steps:');
      print('  1. flutter pub get');
      print('  2. cd ios && pod install');
      print('  3. flutter run --flavor <flavor> -t lib/main.dart');
    }
  }
}
