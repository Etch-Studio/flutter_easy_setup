import 'dart:io';

// FirebaseConfig now names the v2 schema class in the barrel; the v1 class
// under test is imported directly from the legacy model file instead.
import 'package:easy_setup/easy_setup.dart' hide FirebaseConfig;
import 'package:easy_setup/src/models/flavor_config.dart' show FirebaseConfig;
import 'package:test/test.dart';

void main() {
  group('FlavorConfig.fromYaml', () {
    test('parses valid map correctly', () {
      final config = FlavorConfig.fromYaml({
        'bundle_id': 'com.example.app.dev',
        'name': 'MyApp Dev',
      });
      expect(config.bundleId, 'com.example.app.dev');
      expect(config.name, 'MyApp Dev');
    });

    test('throws when bundle_id is missing', () {
      expect(
        () => FlavorConfig.fromYaml({'name': 'MyApp'}),
        throwsA(isA<TypeError>()),
      );
    });

    test('throws when name is missing', () {
      expect(
        () => FlavorConfig.fromYaml({'bundle_id': 'com.example.app'}),
        throwsA(isA<TypeError>()),
      );
    });

    test('parses optional fields when present', () {
      final config = FlavorConfig.fromYaml({
        'bundle_id': 'com.example.app.dev',
        'name': 'MyApp Dev',
        'version_code': 42,
        'version_name': '1.0.0-dev',
        'app_icon': 'assets/icons/dev_icon.png',
        'localized': {
          'ja': {
            'app_name': 'MyApp Dev JA',
          },
          'ko': {
            'app_name': '마이앱 Dev',
          },
        },
        'signing': {
          'keystore': 'keys/dev.keystore',
          'alias': 'dev-key',
        },
        'firebase': {
          'project_id': 'my-firebase-dev',
        },
        'ios': {
          'team_id': 'ABCDEF1234',
          'provisioning_profile': 'Dev Profile',
          'code_sign_identity': 'Apple Development',
          'entitlements': 'ios/Runner/Dev.entitlements',
        },
      });
      expect(config.versionCode, 42);
      expect(config.versionName, '1.0.0-dev');
      expect(config.appIcon, 'assets/icons/dev_icon.png');
      expect(config.localized, isNotNull);
      expect(config.localized!['ja']!.appName, 'MyApp Dev JA');
      expect(config.localized!['ko']!.appName, '마이앱 Dev');
      expect(config.signing, isNotNull);
      expect(config.signing!.keystore, 'keys/dev.keystore');
      expect(config.signing!.alias, 'dev-key');
      expect(config.firebase, isNotNull);
      expect(config.firebase!.projectId, 'my-firebase-dev');
      expect(config.ios, isNotNull);
      expect(config.ios!.teamId, 'ABCDEF1234');
      expect(config.ios!.provisioningProfile, 'Dev Profile');
      expect(config.ios!.codeSignIdentity, 'Apple Development');
      expect(config.ios!.entitlements, 'ios/Runner/Dev.entitlements');
    });

    test('optional fields are null when not provided', () {
      final config = FlavorConfig.fromYaml({
        'bundle_id': 'com.example.app',
        'name': 'MyApp',
      });
      expect(config.versionCode, isNull);
      expect(config.versionName, isNull);
      expect(config.signing, isNull);
      expect(config.firebase, isNull);
      expect(config.ios, isNull);
      expect(config.appIcon, isNull);
      expect(config.localized, isNull);
    });

    test('parses app_icon without localized', () {
      final config = FlavorConfig.fromYaml({
        'bundle_id': 'com.example.app',
        'name': 'MyApp',
        'app_icon': 'assets/icons/icon.png',
      });
      expect(config.appIcon, 'assets/icons/icon.png');
      expect(config.localized, isNull);
    });

    test('parses localized with only app_name', () {
      final config = FlavorConfig.fromYaml({
        'bundle_id': 'com.example.app',
        'name': 'MyApp',
        'localized': {
          'ko': {'app_name': '마이앱'},
        },
      });
      expect(config.localized, isNotNull);
      expect(config.localized!['ko']!.appName, '마이앱');
    });
  });

  group('SigningConfig.fromYaml', () {
    test('parses valid map', () {
      final config = SigningConfig.fromYaml({
        'keystore': 'keys/release.keystore',
        'alias': 'release-key',
      });
      expect(config.keystore, 'keys/release.keystore');
      expect(config.alias, 'release-key');
    });

    test('throws when keystore is missing', () {
      expect(
        () => SigningConfig.fromYaml({'alias': 'key'}),
        throwsA(isA<TypeError>()),
      );
    });

    test('throws when alias is missing', () {
      expect(
        () => SigningConfig.fromYaml({'keystore': 'keys/k.keystore'}),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('FirebaseConfig.fromYaml', () {
    test('parses project_id', () {
      final config = FirebaseConfig.fromYaml({
        'project_id': 'my-firebase-project',
      });
      expect(config.projectId, 'my-firebase-project');
    });

    test('throws when project_id is missing', () {
      expect(
        () => FirebaseConfig.fromYaml({}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('IosFlavorConfig.fromYaml', () {
    test('parses all fields', () {
      final config = IosFlavorConfig.fromYaml({
        'team_id': 'TEAM123',
        'provisioning_profile': 'My Profile',
        'code_sign_identity': 'Apple Distribution',
        'entitlements': 'Runner/Prod.entitlements',
      });
      expect(config.teamId, 'TEAM123');
      expect(config.provisioningProfile, 'My Profile');
      expect(config.codeSignIdentity, 'Apple Distribution');
      expect(config.entitlements, 'Runner/Prod.entitlements');
    });

    test('all fields are optional', () {
      final config = IosFlavorConfig.fromYaml({});
      expect(config.teamId, isNull);
      expect(config.provisioningProfile, isNull);
      expect(config.codeSignIdentity, isNull);
      expect(config.entitlements, isNull);
    });

    test('parses partial fields', () {
      final config = IosFlavorConfig.fromYaml({
        'team_id': 'TEAM123',
      });
      expect(config.teamId, 'TEAM123');
      expect(config.codeSignIdentity, isNull);
      expect(config.provisioningProfile, isNull);
      expect(config.entitlements, isNull);
    });
  });

  group('FlavorLocalizedConfig.fromYaml', () {
    test('parses app_name field', () {
      final config = FlavorLocalizedConfig.fromYaml({
        'app_name': '마이앱',
      });
      expect(config.appName, '마이앱');
    });

    test('app_name field is optional', () {
      final config = FlavorLocalizedConfig.fromYaml({});
      expect(config.appName, isNull);
    });
  });

  group('EasySetupConfig.fromFile', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('flavor_config_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('parses valid YAML file', () {
      final yamlFile = File('${tempDir.path}/easy_setup.yaml');
      yamlFile.writeAsStringSync('''
easy_setup:
  flavors:
    dev:
      bundle_id: com.example.app.dev
      name: MyApp Dev
    prod:
      bundle_id: com.example.app
      name: MyApp
''');

      final config = EasySetupConfig.fromFile(yamlFile.path);
      expect(config.flavors.length, 2);
      expect(config.flavors['dev']!.bundleId, 'com.example.app.dev');
      expect(config.flavors['dev']!.name, 'MyApp Dev');
      expect(config.flavors['prod']!.bundleId, 'com.example.app');
      expect(config.flavors['prod']!.name, 'MyApp');
    });

    test('throws SetupException when file does not exist', () {
      expect(
        () => EasySetupConfig.fromFile('${tempDir.path}/nonexistent.yaml'),
        throwsA(
          isA<SetupException>().having(
            (e) => e.message,
            'message',
            contains('easy_setup.yaml not found'),
          ),
        ),
      );
    });

    test('throws SetupException for invalid YAML', () {
      final yamlFile = File('${tempDir.path}/easy_setup.yaml');
      yamlFile.writeAsStringSync('not: valid: yaml: [[[');

      expect(
        () => EasySetupConfig.fromFile(yamlFile.path),
        throwsA(isA<SetupException>()),
      );
    });

    test('throws SetupException when easy_setup key is missing', () {
      final yamlFile = File('${tempDir.path}/easy_setup.yaml');
      yamlFile.writeAsStringSync('something_else: true\n');

      expect(
        () => EasySetupConfig.fromFile(yamlFile.path),
        throwsA(
          isA<SetupException>().having(
            (e) => e.message,
            'message',
            contains('Missing "easy_setup" key'),
          ),
        ),
      );
    });

    test('throws SetupException when flavors key is missing', () {
      final yamlFile = File('${tempDir.path}/easy_setup.yaml');
      yamlFile.writeAsStringSync('easy_setup:\n  something_else: true\n');

      expect(
        () => EasySetupConfig.fromFile(yamlFile.path),
        throwsA(isA<SetupException>()),
      );
    });

    test('parses multiple flavors', () {
      final yamlFile = File('${tempDir.path}/easy_setup.yaml');
      yamlFile.writeAsStringSync('''
easy_setup:
  flavors:
    dev:
      bundle_id: com.example.dev
      name: Dev
    staging:
      bundle_id: com.example.staging
      name: Staging
    prod:
      bundle_id: com.example.prod
      name: Prod
''');

      final config = EasySetupConfig.fromFile(yamlFile.path);
      expect(config.flavors.length, 3);
      expect(config.flavors.keys, containsAll(['dev', 'staging', 'prod']));
    });

    test('parses YAML with all optional fields', () {
      final yamlFile = File('${tempDir.path}/easy_setup.yaml');
      yamlFile.writeAsStringSync('''
easy_setup:
  localizations: [ko, en, ja]
  flavors:
    dev:
      bundle_id: com.example.app.dev
      name: MyApp Dev
      version_code: 1
      version_name: "1.0.0-dev"
      app_icon: assets/icons/dev_icon.png
      localized:
        ja:
          app_name: MyApp Dev JA
      signing:
        keystore: keys/dev.keystore
        alias: dev-key
      firebase:
        project_id: my-firebase-dev
      ios:
        team_id: "ABCDEF1234"

  permission:
    NSCameraUsageDescription: "Camera access is required"
  localized_permission:
    ko:
      NSCameraUsageDescription: "카메라 접근이 필요합니다"
''');

      final config = EasySetupConfig.fromFile(yamlFile.path);
      final dev = config.flavors['dev']!;
      expect(dev.versionCode, 1);
      expect(dev.versionName, '1.0.0-dev');
      expect(dev.appIcon, 'assets/icons/dev_icon.png');
      expect(dev.localized, isNotNull);
      expect(dev.localized!['ja']!.appName, 'MyApp Dev JA');
      expect(dev.signing!.keystore, 'keys/dev.keystore');
      expect(dev.firebase!.projectId, 'my-firebase-dev');
      expect(dev.ios!.teamId, 'ABCDEF1234');
      // localizations
      expect(config.localizations, ['ko', 'en', 'ja']);
      // Default permission
      expect(config.permission, isNotNull);
      expect(config.permission!['NSCameraUsageDescription'],
          'Camera access is required');
      // Per-locale permission
      expect(config.localizedPermission, isNotNull);
      expect(config.localizedPermission!['ko']!['NSCameraUsageDescription'],
          '카메라 접근이 필요합니다');
    });
  });
}
