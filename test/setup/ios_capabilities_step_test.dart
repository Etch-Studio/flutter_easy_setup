import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../helpers/fake_http_json_client.dart';

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

  SetupContext context(
    ProjectConfig cfg, {
    bool dryRun = false,
    Map<String, String> env = const {},
    HttpJsonClient? http,
  }) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg,
        env: env,
        http: http,
        dryRun: dryRun,
        out: out,
      );

  const ascEnv = {
    'ASC_KEY_ID': 'KEY123',
    'ASC_ISSUER_ID': 'issuer-uuid',
    'ASC_KEY_P8': testEcPrivateKeyPem,
  };

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

    test('without the ASC key it points at the manual portal step',
        () async {
      await IosCapabilitiesStep().run(context(config(fullConfig)));
      expect(out.toString(), contains('developer.apple.com'));
      expect(out.toString(), contains('match --force'));
    });

    test('registers the bundle ID and enables missing capabilities via '
        'the ASC API', () async {
      final http = FakeHttpJsonClient((method, uri, body) {
        if (method == 'GET' && uri.path.endsWith('/bundleIds')) {
          return JsonResponse(200, {'data': []});
        }
        if (method == 'POST' && uri.path.endsWith('/bundleIds')) {
          return JsonResponse(201, {
            'data': {'id': 'RES1'},
          });
        }
        if (uri.path.endsWith('/bundleIdCapabilities') && method == 'GET') {
          return JsonResponse(200, {
            'data': [
              {
                'attributes': {'capabilityType': 'APP_GROUPS'},
              },
            ],
          });
        }
        return JsonResponse(201, {'data': {}});
      });

      await IosCapabilitiesStep()
          .run(context(config(fullConfig), env: ascEnv, http: http));

      // Registered, then only the missing PUSH_NOTIFICATIONS was enabled.
      final posts = http.requests.where((r) => r.$1 == 'POST').toList();
      expect(posts, hasLength(2));
      expect(posts[0].$2.path, endsWith('/bundleIds'));
      final enabled = ((posts[1].$3 as Map)['data'] as Map);
      expect((enabled['attributes'] as Map)['capabilityType'],
          'PUSH_NOTIFICATIONS');

      expect(out.toString(), contains('Registered bundle ID com.x'));
      expect(out.toString(), contains('Enabled PUSH_NOTIFICATIONS'));
      // A portal change warns about invalidated profiles, and app group
      // assignment is honestly reported as a manual step.
      expect(out.toString(), contains('invalidate'));
      expect(out.toString(), contains('group.com.x'));
      expect(out.toString(), contains('not exposed by the public ASC API'));
    });

    test('portal in sync reports up to date without changes', () async {
      final http = FakeHttpJsonClient((method, uri, body) {
        if (method == 'GET' && uri.path.endsWith('/bundleIds')) {
          return JsonResponse(200, {
            'data': [
              {
                'id': 'RES1',
                'attributes': {'identifier': 'com.x'},
              },
            ],
          });
        }
        return JsonResponse(200, {
          'data': [
            {
              'attributes': {'capabilityType': 'PUSH_NOTIFICATIONS'},
            },
            {
              'attributes': {'capabilityType': 'APP_GROUPS'},
            },
          ],
        });
      });

      await IosCapabilitiesStep()
          .run(context(config(fullConfig), env: ascEnv, http: http));
      expect(http.requests.where((r) => r.$1 == 'POST'), isEmpty);
      expect(out.toString(), contains('Portal capabilities up to date'));
    });

    test('dry-run with the ASC key previews without any API call',
        () async {
      final http = FakeHttpJsonClient(
          (method, uri, body) => JsonResponse(500, null));
      await IosCapabilitiesStep().run(
          context(config(fullConfig), env: ascEnv, http: http, dryRun: true));
      expect(http.requests, isEmpty);
      expect(out.toString(), contains('[dry-run] Would ensure bundle ID'));
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
