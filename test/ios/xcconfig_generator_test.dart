import 'dart:io';

import 'package:easy_setup/src/ios/xcconfig_generator.dart';
import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xcconfig_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  const config = FlavorConfig(bundleId: 'com.example.app.dev', name: 'MyApp Dev');

  group('XcconfigGenerator', () {
    test('creates Debug, Release, and Profile xcconfig files', () {
      XcconfigGenerator.generate(tempDir.path, 'dev', config);

      expect(File(p.join(tempDir.path, 'Debug-dev.xcconfig')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'Release-dev.xcconfig')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'Profile-dev.xcconfig')).existsSync(), isTrue);
    });

    test('Debug xcconfig includes Debug.xcconfig', () {
      XcconfigGenerator.generate(tempDir.path, 'dev', config);

      final content = File(p.join(tempDir.path, 'Debug-dev.xcconfig')).readAsStringSync();
      expect(content, contains('#include "Debug.xcconfig"'));
      expect(content, contains('APP_DISPLAY_NAME=MyApp Dev'));
    });

    test('Release xcconfig includes Release.xcconfig', () {
      XcconfigGenerator.generate(tempDir.path, 'dev', config);

      final content = File(p.join(tempDir.path, 'Release-dev.xcconfig')).readAsStringSync();
      expect(content, contains('#include "Release.xcconfig"'));
      expect(content, contains('APP_DISPLAY_NAME=MyApp Dev'));
    });

    test('Profile xcconfig includes Release.xcconfig', () {
      XcconfigGenerator.generate(tempDir.path, 'dev', config);

      final content = File(p.join(tempDir.path, 'Profile-dev.xcconfig')).readAsStringSync();
      expect(content, contains('#include "Release.xcconfig"'));
      expect(content, contains('APP_DISPLAY_NAME=MyApp Dev'));
    });

    test('overwrites existing files with correct content', () {
      XcconfigGenerator.generate(tempDir.path, 'dev', config);
      final afterFirst = File(p.join(tempDir.path, 'Debug-dev.xcconfig')).readAsStringSync();

      // Overwrite with custom content
      File(p.join(tempDir.path, 'Debug-dev.xcconfig')).writeAsStringSync('CUSTOM');

      XcconfigGenerator.generate(tempDir.path, 'dev', config);
      final afterSecond = File(p.join(tempDir.path, 'Debug-dev.xcconfig')).readAsStringSync();

      expect(afterSecond, afterFirst);
    });

    test('does not create files in dry-run mode', () {
      XcconfigGenerator.generate(tempDir.path, 'dev', config, dryRun: true);

      expect(File(p.join(tempDir.path, 'Debug-dev.xcconfig')).existsSync(), isFalse);
      expect(File(p.join(tempDir.path, 'Release-dev.xcconfig')).existsSync(), isFalse);
      expect(File(p.join(tempDir.path, 'Profile-dev.xcconfig')).existsSync(), isFalse);
    });

    test('creates parent directories if they do not exist', () {
      final nestedDir = p.join(tempDir.path, 'ios', 'Flutter');

      XcconfigGenerator.generate(nestedDir, 'dev', config);

      expect(File(p.join(nestedDir, 'Debug-dev.xcconfig')).existsSync(), isTrue);
    });

    test('includes iOS config variables when ios config is present', () {
      const configWithIos = FlavorConfig(
        bundleId: 'com.example.app.dev',
        name: 'MyApp Dev',
        ios: IosFlavorConfig(
          teamId: 'ABCDEF1234',
          codeSignIdentity: 'Apple Development',
          provisioningProfile: 'Dev Profile',
          entitlements: 'ios/Runner/Dev.entitlements',
        ),
      );

      XcconfigGenerator.generate(tempDir.path, 'dev', configWithIos);

      final content = File(p.join(tempDir.path, 'Debug-dev.xcconfig')).readAsStringSync();
      expect(content, contains('APP_DISPLAY_NAME=MyApp Dev'));
      expect(content, contains('DEVELOPMENT_TEAM=ABCDEF1234'));
      expect(content, contains('CODE_SIGN_IDENTITY=Apple Development'));
      expect(content, contains('PROVISIONING_PROFILE_SPECIFIER=Dev Profile'));
      expect(content, contains('CODE_SIGN_ENTITLEMENTS=ios/Runner/Dev.entitlements'));
    });

    test('includes only provided iOS config variables (partial)', () {
      const configWithPartialIos = FlavorConfig(
        bundleId: 'com.example.app.dev',
        name: 'MyApp Dev',
        ios: IosFlavorConfig(
          teamId: 'TEAM123',
        ),
      );

      XcconfigGenerator.generate(tempDir.path, 'dev', configWithPartialIos);

      final content = File(p.join(tempDir.path, 'Debug-dev.xcconfig')).readAsStringSync();
      expect(content, contains('APP_DISPLAY_NAME=MyApp Dev'));
      expect(content, contains('DEVELOPMENT_TEAM=TEAM123'));
      expect(content, isNot(contains('CODE_SIGN_IDENTITY=')));
      expect(content, isNot(contains('PROVISIONING_PROFILE_SPECIFIER=')));
      expect(content, isNot(contains('CODE_SIGN_ENTITLEMENTS=')));
    });

    test('auto-sets ASSETCATALOG_COMPILER_APPICON_NAME when appIcon is set', () {
      const configWithAppIcon = FlavorConfig(
        bundleId: 'com.example.app.dev',
        name: 'MyApp Dev',
        appIcon: 'assets/icons/dev_icon.png',
      );

      XcconfigGenerator.generate(tempDir.path, 'dev', configWithAppIcon);

      final content = File(p.join(tempDir.path, 'Debug-dev.xcconfig')).readAsStringSync();
      expect(content, contains('ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-dev'));
    });

    test('does not set ASSETCATALOG_COMPILER_APPICON_NAME when appIcon is null', () {
      XcconfigGenerator.generate(tempDir.path, 'dev', config);

      final content = File(p.join(tempDir.path, 'Debug-dev.xcconfig')).readAsStringSync();
      expect(content, isNot(contains('ASSETCATALOG_COMPILER_APPICON_NAME=')));
    });

    test('does not include iOS variables when ios config is absent', () {
      XcconfigGenerator.generate(tempDir.path, 'dev', config);

      final content = File(p.join(tempDir.path, 'Debug-dev.xcconfig')).readAsStringSync();
      expect(content, contains('APP_DISPLAY_NAME=MyApp Dev'));
      expect(content, isNot(contains('DEVELOPMENT_TEAM=')));
      expect(content, isNot(contains('CODE_SIGN_IDENTITY=')));
      expect(content, isNot(contains('PROVISIONING_PROFILE_SPECIFIER=')));
      expect(content, isNot(contains('CODE_SIGN_ENTITLEMENTS=')));
      expect(content, isNot(contains('ASSETCATALOG_COMPILER_APPICON_NAME=')));
    });

    test('iOS config variables appear in all three xcconfig files', () {
      const configWithIos = FlavorConfig(
        bundleId: 'com.example.app.dev',
        name: 'MyApp Dev',
        ios: IosFlavorConfig(teamId: 'TEAM123'),
      );

      XcconfigGenerator.generate(tempDir.path, 'dev', configWithIos);

      for (final prefix in ['Debug', 'Release', 'Profile']) {
        final content = File(p.join(tempDir.path, '$prefix-dev.xcconfig')).readAsStringSync();
        expect(content, contains('DEVELOPMENT_TEAM=TEAM123'),
            reason: '$prefix xcconfig should contain DEVELOPMENT_TEAM');
      }
    });
  });
}
