import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _manifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="app"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity" />
    </application>
</manifest>
''';

const _infoPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>app</string>
</dict>
</plist>
''';

const _iosAppId = 'ca-app-pub-1234567890123456~1111111111';
const _androidAppId = 'ca-app-pub-1234567890123456~2222222222';

void main() {
  late Directory tempDir;
  late StringBuffer out;
  late File manifestFile;
  late File plistFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('admob_step_test');
    out = StringBuffer();
    manifestFile = File(ProjectFinder.androidManifestPath(tempDir.path))
      ..createSync(recursive: true)
      ..writeAsStringSync(_manifest);
    plistFile = File(ProjectFinder.iosInfoPlistPath(tempDir.path))
      ..createSync(recursive: true)
      ..writeAsStringSync(_infoPlist);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config([String extra = '']) => ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
admob:
  ios_app_id: $_iosAppId
  android_app_id: $_androidAppId
$extra
''') as Map);

  SetupContext context({ProjectConfig? cfg, bool dryRun = false}) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: const {},
        dryRun: dryRun,
        out: out,
      );

  group('AdmobStep', () {
    test('injects APPLICATION_ID into AndroidManifest.xml', () async {
      await AdmobStep().run(context());
      final manifest = manifestFile.readAsStringSync();
      expect(manifest, contains('com.google.android.gms.ads.APPLICATION_ID'));
      expect(manifest, contains(_androidAppId));
      // Inserted inside <application>.
      expect(manifest.indexOf('APPLICATION_ID'),
          lessThan(manifest.indexOf('</application>')));
    });

    test('injects GADApplicationIdentifier and SKAdNetworkItems', () async {
      await AdmobStep().run(context());
      final plist = plistFile.readAsStringSync();
      expect(plist, contains('<key>GADApplicationIdentifier</key>'));
      expect(plist, contains(_iosAppId));
      expect(plist, contains(AdmobStep.googleSkAdNetworkId));
      // Still one closing dict at the plist root level after insertion.
      expect('</plist>'.allMatches(plist), hasLength(1));
    });

    test('is idempotent — second run changes nothing', () async {
      await AdmobStep().run(context());
      final manifestAfterFirst = manifestFile.readAsStringSync();
      final plistAfterFirst = plistFile.readAsStringSync();

      await AdmobStep().run(context());
      expect(manifestFile.readAsStringSync(), manifestAfterFirst);
      expect(plistFile.readAsStringSync(), plistAfterFirst);
      expect(out.toString(), contains('up to date'));
    });

    test('updates a changed app ID in place', () async {
      await AdmobStep().run(context());
      const newId = 'ca-app-pub-9999999999999999~3333333333';
      await AdmobStep().run(context(
          cfg: ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
admob:
  ios_app_id: $newId
  android_app_id: $newId
''') as Map)));
      expect(manifestFile.readAsStringSync(), contains(newId));
      expect(manifestFile.readAsStringSync(), isNot(contains(_androidAppId)));
      expect(plistFile.readAsStringSync(), contains(newId));
      expect(plistFile.readAsStringSync(), isNot(contains(_iosAppId)));
    });

    test('writes test IDs to env.json and real IDs to env.prod.json',
        () async {
      await AdmobStep().run(context(
          cfg: config('''
  ad_units:
    banner_main:
      type: banner
      ios: ca-app-pub-1234567890123456/1010101010
      android: ca-app-pub-1234567890123456/2020202020
''')));
      final debug = json.decode(
          File(p.join(tempDir.path, 'env.json')).readAsStringSync()) as Map;
      final prod = json.decode(
              File(p.join(tempDir.path, 'env.prod.json')).readAsStringSync())
          as Map;
      expect(debug['ADMOB_BANNER_MAIN_ANDROID'],
          AdmobStep.testAdUnits['android']!['banner']);
      expect(debug['ADMOB_BANNER_MAIN_IOS'],
          AdmobStep.testAdUnits['ios']!['banner']);
      expect(prod['ADMOB_BANNER_MAIN_ANDROID'],
          'ca-app-pub-1234567890123456/2020202020');
      expect(prod['ADMOB_BANNER_MAIN_IOS'],
          'ca-app-pub-1234567890123456/1010101010');
    });

    test('without a type, env.json falls back to the real ID', () async {
      await AdmobStep().run(context(
          cfg: config('''
  ad_units:
    banner_main:
      android: ca-app-pub-1234567890123456/2020202020
''')));
      final debug = json.decode(
          File(p.join(tempDir.path, 'env.json')).readAsStringSync()) as Map;
      expect(debug['ADMOB_BANNER_MAIN_ANDROID'],
          'ca-app-pub-1234567890123456/2020202020');
    });

    test('updates the app ID even when XML attributes are reordered',
        () async {
      manifestFile.writeAsStringSync('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="app">
        <meta-data
            android:value="ca-app-pub-0000000000000000~0000000000"
            android:name="com.google.android.gms.ads.APPLICATION_ID" />
    </application>
</manifest>
''');
      await AdmobStep().run(context());
      final manifest = manifestFile.readAsStringSync();
      expect(manifest, contains(_androidAppId));
      expect(manifest, isNot(contains('~0000000000')));
    });

    test('appends the Google ID to an existing SKAdNetworkItems array',
        () async {
      plistFile.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>SKAdNetworkItems</key>
	<array>
		<dict>
			<key>SKAdNetworkIdentifier</key>
			<string>other9network.skadnetwork</string>
		</dict>
	</array>
</dict>
</plist>
''');
      await AdmobStep().run(context());
      final plist = plistFile.readAsStringSync();
      expect(plist, contains(AdmobStep.googleSkAdNetworkId));
      expect(plist, contains('other9network.skadnetwork'));
      // No second SKAdNetworkItems key was introduced.
      expect('<key>SKAdNetworkItems</key>'.allMatches(plist), hasLength(1));
    });

    test('removed ad units are cleaned from the env files', () async {
      File(p.join(tempDir.path, 'env.json')).writeAsStringSync(
          '{"KEEP": "me", "ADMOB_OLD_BANNER_IOS": "stale"}');
      await AdmobStep().run(context(
          cfg: config('''
  ad_units:
    banner_main: { android: ca-app-pub-1234567890123456/2020202020 }
''')));
      final debug = json.decode(
          File(p.join(tempDir.path, 'env.json')).readAsStringSync()) as Map;
      expect(debug['KEEP'], 'me');
      expect(debug.containsKey('ADMOB_OLD_BANNER_IOS'), isFalse);
      expect(debug['ADMOB_BANNER_MAIN_ANDROID'],
          'ca-app-pub-1234567890123456/2020202020');
    });

    test('dry-run touches nothing', () async {
      await AdmobStep().run(context(dryRun: true));
      expect(manifestFile.readAsStringSync(), _manifest);
      expect(plistFile.readAsStringSync(), _infoPlist);
      expect(File(p.join(tempDir.path, 'env.json')).existsSync(), isFalse);
      expect(out.toString(), contains('[dry-run]'));
    });

    test('warns when app IDs are missing but still writes ad units',
        () async {
      await AdmobStep().run(context(
          cfg: ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
admob:
  ad_units:
    banner_main: { android: ca-app-pub-1234567890123456/2020202020 }
''') as Map)));
      expect(out.toString(), contains('Missing app ID'));
      expect(File(p.join(tempDir.path, 'env.prod.json')).existsSync(),
          isTrue);
      expect(manifestFile.readAsStringSync(), _manifest);
    });
  });
}
