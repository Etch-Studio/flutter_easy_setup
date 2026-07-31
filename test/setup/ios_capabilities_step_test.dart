import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _infoPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>app</string>
</dict>
</plist>
''';

void main() {
  late Directory tempDir;
  late StringBuffer out;
  late File plistFile;
  late File debugXcconfig;
  late File releaseXcconfig;
  late File entitlementsFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ios_capabilities_test');
    out = StringBuffer();
    plistFile = File(ProjectFinder.iosInfoPlistPath(tempDir.path))
      ..createSync(recursive: true)
      ..writeAsStringSync(_infoPlist);
    final xcconfigDir = Directory(ProjectFinder.iosXcconfigDir(tempDir.path))
      ..createSync(recursive: true);
    debugXcconfig = File(p.join(xcconfigDir.path, 'Debug.xcconfig'))
      ..writeAsStringSync('#include "Generated.xcconfig"\n');
    releaseXcconfig = File(p.join(xcconfigDir.path, 'Release.xcconfig'))
      ..writeAsStringSync('#include "Generated.xcconfig"\n');
    entitlementsFile = File(
        p.join(tempDir.path, IosCapabilitiesStep.entitlementsRelativePath));
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config(String iosSection) => ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
ios:
$iosSection
''') as Map);

  SetupContext context(ProjectConfig cfg, {bool dryRun = false}) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg,
        env: const {},
        dryRun: dryRun,
        out: out,
      );

  final fullConfig = '''
  capabilities:
    - push_notifications
    - app_groups: [group.com.x]
  background_modes: [audio, fetch]
''';

  group('IosCapabilitiesStep', () {
    test('is configured only when capabilities or background modes exist',
        () {
      final step = IosCapabilitiesStep();
      expect(step.isConfigured(config('  team_id: ABCDE12345')), isFalse);
      expect(step.isConfigured(config('  background_modes: [audio]')),
          isTrue);
    });

    test('generates entitlements, wires xcconfigs, injects background modes',
        () async {
      await IosCapabilitiesStep().run(context(config(fullConfig)));

      final entitlements = entitlementsFile.readAsStringSync();
      expect(entitlements, contains('<key>aps-environment</key>'));
      expect(entitlements, contains('<string>group.com.x</string>'));

      for (final xcconfig in [debugXcconfig, releaseXcconfig]) {
        expect(xcconfig.readAsStringSync(),
            contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements'));
      }

      final plist = plistFile.readAsStringSync();
      expect(plist, contains('<key>UIBackgroundModes</key>'));
      expect(plist, contains('<string>audio</string>'));
      expect(plist, contains('<string>fetch</string>'));
    });

    test('is idempotent — second run changes nothing', () async {
      await IosCapabilitiesStep().run(context(config(fullConfig)));
      final entitlementsAfter = entitlementsFile.readAsStringSync();
      final debugAfter = debugXcconfig.readAsStringSync();
      final plistAfter = plistFile.readAsStringSync();

      await IosCapabilitiesStep().run(context(config(fullConfig)));
      expect(entitlementsFile.readAsStringSync(), entitlementsAfter);
      expect(debugXcconfig.readAsStringSync(), debugAfter);
      expect(plistFile.readAsStringSync(), plistAfter);
      expect(out.toString(), contains('up to date'));
    });

    test('merges into existing entitlements and background modes', () async {
      entitlementsFile
        ..createSync(recursive: true)
        ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.existing</string>
	</array>
</dict>
</plist>
''');
      plistFile.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>UIBackgroundModes</key>
	<array>
		<string>audio</string>
	</array>
</dict>
</plist>
''');
      await IosCapabilitiesStep().run(context(config(fullConfig)));

      final entitlements = entitlementsFile.readAsStringSync();
      expect(entitlements, contains('<string>group.existing</string>'));
      expect(entitlements, contains('<string>group.com.x</string>'));
      expect(entitlements, contains('<key>aps-environment</key>'));

      final plist = plistFile.readAsStringSync();
      expect(plist, contains('<string>audio</string>'));
      expect(plist, contains('<string>fetch</string>'));
      expect('<key>UIBackgroundModes</key>'.allMatches(plist), hasLength(1));
    });

    test('adds a mode even when the same string exists under another key',
        () async {
      plistFile.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>SomeOtherList</key>
	<array>
		<string>audio</string>
	</array>
	<key>UIBackgroundModes</key>
	<array>
		<string>fetch</string>
	</array>
</dict>
</plist>
''');
      await IosCapabilitiesStep().run(context(config(fullConfig)));
      final modes =
          PlistText.arrayContent(plistFile.readAsStringSync(), 'UIBackgroundModes')!;
      expect(modes, contains('audio'));
      expect(modes, contains('fetch'));
    });

    test('an existing foreign CODE_SIGN_ENTITLEMENTS warns instead of '
        'duplicating', () async {
      debugXcconfig.writeAsStringSync(
          'CODE_SIGN_ENTITLEMENTS = Runner/Custom.entitlements\n');
      await IosCapabilitiesStep().run(context(config(fullConfig)));
      expect(out.toString(), contains('Custom.entitlements'));
      expect(
          'CODE_SIGN_ENTITLEMENTS'
              .allMatches(debugXcconfig.readAsStringSync()),
          hasLength(1));
    });

    test('wires Profile.xcconfig when it exists', () async {
      final profile = File(p.join(
          ProjectFinder.iosXcconfigDir(tempDir.path), 'Profile.xcconfig'))
        ..writeAsStringSync('#include "Generated.xcconfig"\n');
      await IosCapabilitiesStep().run(context(config(fullConfig)));
      expect(profile.readAsStringSync(),
          contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements'));
    });

    test('warns when remote-notification lacks push_notifications', () async {
      await IosCapabilitiesStep().run(context(config('''
  background_modes: [remote-notification]
''')));
      expect(out.toString(), contains('push_notifications capability'));
    });

    test('warns about unsupported capability entries', () async {
      await IosCapabilitiesStep().run(context(config('''
  capabilities:
    - healthkit
  background_modes: [audio]
''')));
      expect(out.toString(), contains('healthkit'));
      // No entitlements were generated for unsupported-only capabilities.
      expect(entitlementsFile.existsSync(), isFalse);
    });

    test('always points at the manual portal step', () async {
      await IosCapabilitiesStep().run(context(config(fullConfig)));
      expect(out.toString(), contains('developer.apple.com'));
      expect(out.toString(), contains('match --force'));
    });

    test('dry-run touches nothing', () async {
      await IosCapabilitiesStep()
          .run(context(config(fullConfig), dryRun: true));
      expect(entitlementsFile.existsSync(), isFalse);
      expect(debugXcconfig.readAsStringSync(),
          isNot(contains('CODE_SIGN_ENTITLEMENTS')));
      expect(plistFile.readAsStringSync(), _infoPlist);
      expect(out.toString(), contains('[dry-run]'));
    });
  });
}
