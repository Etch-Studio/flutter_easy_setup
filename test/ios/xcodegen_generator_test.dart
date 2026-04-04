import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String projectRoot;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xcodegen_gen_test_');
    projectRoot = tempDir.path;
    Directory(p.join(projectRoot, 'ios')).createSync(recursive: true);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('XcodeGenGenerator', () {
    test('generates project.yml with basic flavors', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
        'prod': const FlavorConfig(
          bundleId: 'com.example.prod',
          name: 'MyApp',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors);

      final ymlPath = p.join(projectRoot, 'ios', 'project.yml');
      expect(File(ymlPath).existsSync(), isTrue);

      final content = File(ymlPath).readAsStringSync();

      // name
      expect(content, contains('name: Runner'));

      // configs
      expect(content, contains('Debug-dev: debug'));
      expect(content, contains('Release-dev: release'));
      expect(content, contains('Profile-dev: none'));
      expect(content, contains('Debug-prod: debug'));
      expect(content, contains('Release-prod: release'));
      expect(content, contains('Profile-prod: none'));

      // configFiles
      expect(content, contains('Debug-dev: Flutter/Debug-dev.xcconfig'));
      expect(content, contains('Release-dev: Flutter/Release-dev.xcconfig'));
      expect(content, contains('Profile-dev: Flutter/Profile-dev.xcconfig'));

      // bundle IDs in settings
      expect(content, contains('PRODUCT_BUNDLE_IDENTIFIER: com.example.dev'));
      expect(content, contains('PRODUCT_BUNDLE_IDENTIFIER: com.example.prod'));
    });

    test('generates schemes for each flavor', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
        'prod': const FlavorConfig(
          bundleId: 'com.example.prod',
          name: 'MyApp',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors);

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      // Runner scheme
      expect(content, contains('  Runner:'));

      // flavor schemes
      expect(content, contains('  dev:'));
      expect(content, contains('      config: Debug-dev'));
      expect(content, contains('      config: Release-dev'));
      expect(content, contains('      config: Profile-dev'));

      expect(content, contains('  prod:'));
      expect(content, contains('      config: Debug-prod'));
      expect(content, contains('      config: Release-prod'));
      expect(content, contains('      config: Profile-prod'));
    });

    test('includes knownRegions when localizations provided', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
      };

      XcodeGenGenerator.generate(
        projectRoot,
        flavors,
        localizations: ['en', 'ko', 'ja'],
      );

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      expect(content, contains('knownRegions:'));
      expect(content, contains('    - Base'));
      expect(content, contains('    - en'));
      expect(content, contains('    - ko'));
      expect(content, contains('    - ja'));
    });

    test('does not include knownRegions without localizations', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors);

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      expect(content, isNot(contains('knownRegions:')));
    });

    test('sets ASSETCATALOG_COMPILER_APPICON_NAME for flavors with app_icon',
        () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
          appIcon: 'assets/icons/dev.png',
        ),
        'prod': const FlavorConfig(
          bundleId: 'com.example.prod',
          name: 'MyApp',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors);

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      // dev has app_icon → should have custom icon name
      expect(content,
          contains('ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon-dev'));

      // prod has no app_icon → should NOT have custom icon name
      expect(content,
          isNot(contains('ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon-prod')));
    });

    test('does not write files in dry-run mode', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors, dryRun: true);

      final ymlPath = p.join(projectRoot, 'ios', 'project.yml');
      expect(File(ymlPath).existsSync(), isFalse);
    });

    test('overwrites existing file on re-run (idempotent)', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors);
      final first =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      XcodeGenGenerator.generate(projectRoot, flavors);
      final second =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      expect(second, first);
    });

    test('includes RunnerTests target', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors);

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      expect(content, contains('RunnerTests:'));
      expect(content, contains('type: bundle.unit-test'));
      expect(content, contains('- target: Runner'));
    });

    test('includes build scripts references', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors);

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      expect(content, contains('xcodegen/script/run_script.sh'));
      expect(content, contains('xcodegen/script/thin_binary.sh'));
    });

    test('includes copy_firebase_plist.sh when hasFirebase is true', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors, hasFirebase: true);

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      expect(content, contains('xcodegen/script/copy_firebase_plist.sh'));
      expect(content, contains('Copy Firebase Config'));
    });

    test('excludes copy_firebase_plist.sh when hasFirebase is false', () {
      final flavors = {
        'dev': const FlavorConfig(
          bundleId: 'com.example.dev',
          name: 'MyApp Dev',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors, hasFirebase: false);

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      expect(content, isNot(contains('copy_firebase_plist.sh')));
      expect(content, isNot(contains('Copy Firebase Config')));
    });

    test('generates single flavor correctly', () {
      final flavors = {
        'prod': const FlavorConfig(
          bundleId: 'com.example.prod',
          name: 'MyApp',
        ),
      };

      XcodeGenGenerator.generate(projectRoot, flavors);

      final content =
          File(p.join(projectRoot, 'ios', 'project.yml')).readAsStringSync();

      // Only prod flavor configs should exist
      expect(content, contains('Debug-prod: debug'));
      expect(content, isNot(contains('Debug-dev:')));
    });
  });
}
