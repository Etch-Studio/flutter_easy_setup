import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Minimal build.gradle fixture with buildTypes block.
const _buildGradle = '''
android {
    buildTypes {
        release {
            signingConfig signingConfigs.debug
        }
    }
}
''';

/// Minimal Info.plist fixture.
const _infoPlist = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>CFBundleName</key>
\t<string>Runner</string>
\t<key>CFBundleDisplayName</key>
\t<string>Runner</string>
</dict>
</plist>
''';

/// Minimal Podfile fixture with the Release marker.
const _podfile = '''
platform :ios, '12.0'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}
''';

const _easySetupYaml = '''
easy_setup:
  flavors:
    dev:
      bundle_id: com.example.app.dev
      name: MyApp Dev
    prod:
      bundle_id: com.example.app
      name: MyApp
''';

const _easySetupYamlWithFirebase = '''
easy_setup:
  flavors:
    dev:
      bundle_id: com.example.app.dev
      name: MyApp Dev
      firebase:
        project_id: my-firebase-dev
    prod:
      bundle_id: com.example.app
      name: MyApp
''';

/// Creates a minimal Flutter project directory structure for integration tests.
Directory _createFlutterProject(Directory parent, {String? yamlContent}) {
  final root = parent;

  // pubspec.yaml (Flutter project)
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: my_app
dependencies:
  flutter:
    sdk: flutter
''');

  // easy_setup.yaml
  File(p.join(root.path, 'easy_setup.yaml'))
      .writeAsStringSync(yamlContent ?? _easySetupYaml);

  // Android
  final androidAppDir = Directory(p.join(root.path, 'android', 'app'));
  androidAppDir.createSync(recursive: true);
  File(p.join(androidAppDir.path, 'build.gradle'))
      .writeAsStringSync(_buildGradle);

  // iOS
  final flutterDir = Directory(p.join(root.path, 'ios', 'Flutter'));
  flutterDir.createSync(recursive: true);
  // Default Flutter xcconfig files (referenced by XcodeGen configFiles)
  File(p.join(flutterDir.path, 'Debug.xcconfig'))
      .writeAsStringSync('#include "Generated.xcconfig"\n');
  File(p.join(flutterDir.path, 'Release.xcconfig'))
      .writeAsStringSync('#include "Generated.xcconfig"\n');

  final runnerDir = Directory(p.join(root.path, 'ios', 'Runner'));
  runnerDir.createSync(recursive: true);
  File(p.join(runnerDir.path, 'Info.plist')).writeAsStringSync(_infoPlist);
  // Runner-Bridging-Header.h (referenced by XcodeGen Runner target)
  File(p.join(runnerDir.path, 'Runner-Bridging-Header.h'))
      .writeAsStringSync('#import <Flutter/Flutter.h>\n');

  // RunnerTests directory (referenced by XcodeGen RunnerTests target)
  Directory(p.join(root.path, 'ios', 'RunnerTests')).createSync(recursive: true);

  File(p.join(root.path, 'ios', 'Podfile')).writeAsStringSync(_podfile);

  return root;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('flavor_cmd_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('FlavorCommand', () {
    test('throws SetupException when Flutter root not found', () {
      // Use a temp dir that has no pubspec.yaml
      final emptyDir = Directory(p.join(tempDir.path, 'empty'));
      emptyDir.createSync();

      final saved = Directory.current;
      try {
        Directory.current = emptyDir;
        expect(
          () => FlavorCommand.run(),
          throwsA(
            isA<SetupException>().having(
              (e) => e.message,
              'message',
              contains('Could not find a Flutter project root'),
            ),
          ),
        );
      } finally {
        Directory.current = saved;
      }
    });

    test('throws SetupException when flavors are empty', () {
      File(p.join(tempDir.path, 'easy_setup.yaml'))
          .writeAsStringSync('easy_setup:\n  flavors:\n');

      expect(
        () => FlavorCommand.run(projectRoot: tempDir.path),
        throwsA(isA<SetupException>()),
      );
    });


    test('dry-run does not modify any files', () async {
      final root = _createFlutterProject(tempDir);

      final gradleBefore =
          File(p.join(root.path, 'android', 'app', 'build.gradle'))
              .readAsStringSync();
      final plistBefore =
          File(p.join(root.path, 'ios', 'Runner', 'Info.plist'))
              .readAsStringSync();
      final podfileBefore =
          File(p.join(root.path, 'ios', 'Podfile')).readAsStringSync();

      await FlavorCommand.run(projectRoot: root.path, dryRun: true);

      expect(
        File(p.join(root.path, 'android', 'app', 'build.gradle'))
            .readAsStringSync(),
        gradleBefore,
      );
      expect(
        File(p.join(root.path, 'ios', 'Runner', 'Info.plist'))
            .readAsStringSync(),
        plistBefore,
      );
      expect(
        File(p.join(root.path, 'ios', 'Podfile')).readAsStringSync(),
        podfileBefore,
      );
      // xcconfig files should not be created
      expect(
        File(p.join(root.path, 'ios', 'Flutter', 'Debug-dev.xcconfig'))
            .existsSync(),
        isFalse,
      );
      // project.yml should not be created
      expect(
        File(p.join(root.path, 'ios', 'project.yml')).existsSync(),
        isFalse,
      );
    });

    test('full pipeline generates xcconfig, project.yml, and scripts', () async {
      final root = _createFlutterProject(tempDir);

      await FlavorCommand.run(projectRoot: root.path);

      // Android build.gradle should have flavorDimensions
      final gradle =
          File(p.join(root.path, 'android', 'app', 'build.gradle'))
              .readAsStringSync();
      expect(gradle, contains('flavorDimensions'));
      expect(gradle, contains('productFlavors'));

      // iOS xcconfig files should be created
      expect(
        File(p.join(root.path, 'ios', 'Flutter', 'Debug-dev.xcconfig'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(root.path, 'ios', 'Flutter', 'Release-prod.xcconfig'))
            .existsSync(),
        isTrue,
      );

      // project.yml should be generated
      final projectYml =
          File(p.join(root.path, 'ios', 'project.yml')).readAsStringSync();
      expect(projectYml, contains('name: Runner'));
      expect(projectYml, contains('Debug-dev: debug'));
      expect(projectYml, contains('Release-prod: release'));
      expect(projectYml,
          contains('PRODUCT_BUNDLE_IDENTIFIER: com.example.app.dev'));
      expect(projectYml,
          contains('PRODUCT_BUNDLE_IDENTIFIER: com.example.app'));

      // Build scripts should be generated
      expect(
        File(p.join(
                root.path, 'ios', 'xcodegen', 'script', 'run_script.sh'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(
                root.path, 'ios', 'xcodegen', 'script', 'thin_binary.sh'))
            .existsSync(),
        isTrue,
      );

      // Info.plist should use APP_DISPLAY_NAME variable
      final plist =
          File(p.join(root.path, 'ios', 'Runner', 'Info.plist'))
              .readAsStringSync();
      expect(plist, contains(r'$(APP_DISPLAY_NAME)'));

      // Podfile should have flavor mappings
      final podfile =
          File(p.join(root.path, 'ios', 'Podfile')).readAsStringSync();
      expect(podfile, contains("'Debug-dev' => :debug,"));
      expect(podfile, contains("'Release-prod' => :release,"));
    });

    test('dry-run with firebase does not run flutterfire', () async {
      final root = _createFlutterProject(tempDir,
          yamlContent: _easySetupYamlWithFirebase);

      // dry-run should not attempt to run flutterfire
      await FlavorCommand.run(projectRoot: root.path, dryRun: true);

      // No firebase output files should be created
      final androidDest = File(p.join(
        root.path,
        'android',
        'app',
        'src',
        'dev',
        'google-services.json',
      ));
      expect(androidDest.existsSync(), isFalse);
    });

    test('each flavor generates its own localized strings in Flavors dir', () async {
      final multiFlavorYaml = '''
easy_setup:
  flavors:
    dev:
      bundle_id: com.example.dev
      name: Test Dev
      localized:
        ko:
          app_name: 개발 앱
    prod:
      bundle_id: com.example.prod
      name: Test Prod
      localized:
        ko:
          app_name: 상용 앱
''';

      final root =
          _createFlutterProject(tempDir, yamlContent: multiFlavorYaml);
      await FlavorCommand.run(projectRoot: root.path);

      // dev flavor's ko strings
      final devKo = File(p.join(root.path, 'ios', 'Flavors', 'dev',
              'ko.lproj', 'InfoPlist.strings'))
          .readAsStringSync();
      expect(devKo, contains('"CFBundleDisplayName" = "개발 앱";'));

      // dev flavor's en strings (uses flavor name)
      final devEn = File(p.join(root.path, 'ios', 'Flavors', 'dev',
              'en.lproj', 'InfoPlist.strings'))
          .readAsStringSync();
      expect(devEn, contains('"CFBundleDisplayName" = "Test Dev";'));

      // prod flavor's ko strings
      final prodKo = File(p.join(root.path, 'ios', 'Flavors', 'prod',
              'ko.lproj', 'InfoPlist.strings'))
          .readAsStringSync();
      expect(prodKo, contains('"CFBundleDisplayName" = "상용 앱";'));

      // prod flavor's en strings
      final prodEn = File(p.join(root.path, 'ios', 'Flavors', 'prod',
              'en.lproj', 'InfoPlist.strings'))
          .readAsStringSync();
      expect(prodEn, contains('"CFBundleDisplayName" = "Test Prod";'));

      // Verify build phase script was generated
      expect(
        File(p.join(root.path, 'ios', 'xcodegen', 'script',
                'copy_flavor_strings.sh'))
            .existsSync(),
        isTrue,
      );

      // Verify project.yml includes the Copy Flavor Strings script
      final projectYml =
          File(p.join(root.path, 'ios', 'project.yml')).readAsStringSync();
      expect(projectYml, contains('Copy Flavor Strings'));
      expect(projectYml, contains('copy_flavor_strings.sh'));
    });
  });
}
