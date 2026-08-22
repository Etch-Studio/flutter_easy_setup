import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../helpers/fake_http_json_client.dart';

/// No CLI is installed — keeps the AdMob credential chain from reaching for
/// gcloud (and the network) during tests.
class _NoToolProcessRunner extends ProcessRunner {
  @override
  Future<String?> which(String command) async => null;
}

/// A runner where `dart` exists, recording what was asked of it.
///
/// [formatted] stands in for what `dart format` would leave in the scratch
/// file, so tests can tell whether the formatter's output is what gets
/// written. [exitCode] and [throws] cover the ways the real one can fail.
class _DartProcessRunner extends ProcessRunner {
  final ran = <(String, List<String>)>[];
  final String? formatted;
  final int exitCode;
  final bool throws;

  _DartProcessRunner({this.formatted, this.exitCode = 0, this.throws = false});

  @override
  Future<String?> which(String command) async =>
      command == 'dart' ? '/usr/bin/dart' : null;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    ran.add((executable, arguments));
    if (throws) throw ProcessException(executable, arguments, 'broken');
    final target = formatted;
    if (target != null) File(arguments.last).writeAsStringSync(target);
    return ProcessResult(0, exitCode, '', '');
  }
}

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

  SetupContext context({
    ProjectConfig? cfg,
    bool dryRun = false,
    bool adopt = false,
    Map<String, String> env = const {},
    HttpJsonClient? http,
    ProcessRunner? processes,
  }) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: env,
        processes: processes ?? _NoToolProcessRunner(),
        http: http,
        dryRun: dryRun,
        adopt: adopt,
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
      expect(out.toString(), contains('No ios app ID'));
      expect(out.toString(), contains('No android app ID'));
      // The credential hint is printed once, not once per platform.
      expect('AdMob API access needs'.allMatches(out.toString()), hasLength(1));
      expect(File(p.join(tempDir.path, 'env.prod.json')).existsSync(),
          isTrue);
      expect(manifestFile.readAsStringSync(), _manifest);
    });
  });

  group('AdmobStep ad ID accessors', () {
    File adIds() => File(p.join(tempDir.path, AdmobStep.adIdsPath));

    ProjectConfig withUnits([String units = '''
  ad_units:
    banner_main:
      type: banner
''']) =>
        config(units);

    test('writes one accessor per declared unit', () async {
      await AdmobStep().run(context(cfg: withUnits()));
      final source = adIds().readAsStringSync();
      expect(source, contains("String.fromEnvironment('ADMOB_BANNER_MAIN_IOS')"));
      expect(source,
          contains("String.fromEnvironment('ADMOB_BANNER_MAIN_ANDROID')"));
      expect(source, contains('static String? get bannerMain'));
      expect(out.toString(), contains('Wrote ${AdmobStep.adIdsPath}'));
    });

    test('debug falls back to the test unit for the declared type', () async {
      await AdmobStep().run(context(cfg: withUnits()));
      final source = adIds().readAsStringSync();
      // The banner test units, and only in the debug branch.
      expect(source, contains('ca-app-pub-3940256099942544/2934735716'));
      expect(source, contains('ca-app-pub-3940256099942544/6300978111'));
      expect(source, contains('if (!kDebugMode) return null;'));
    });

    test('a unit without a type has nothing to fall back to', () async {
      await AdmobStep().run(context(cfg: withUnits('''
  ad_units:
    house_slot:
      ios: ca-app-pub-1234567890123456/1111111111
''')));
      final source = adIds().readAsStringSync();
      expect(source, contains('static String? get houseSlot'));
      expect(source, isNot(contains('kDebugMode')));
      expect(source, isNot(contains('ca-app-pub-3940256099942544')));
    });

    test('a second run writes nothing', () async {
      await AdmobStep().run(context(cfg: withUnits()));
      final first = adIds().readAsStringSync();
      out.clear();
      await AdmobStep().run(context(cfg: withUnits()));
      expect(adIds().readAsStringSync(), first);
      expect(out.toString(), contains('up to date'));
    });

    test('the yaml wins over an edit inside the generated file', () async {
      await AdmobStep().run(context(cfg: withUnits()));
      // A real hand edit changes the body and leaves the header — which is
      // the header that says edits are overwritten.
      adIds().writeAsStringSync(
        adIds().readAsStringSync().replaceAll('bannerMain', 'myBanner'),
      );
      await AdmobStep().run(context(cfg: withUnits()));
      final source = adIds().readAsStringSync();
      expect(source, contains('get bannerMain'));
      expect(source, isNot(contains('myBanner')));
    });

    test('a unit added to the yaml gets an accessor', () async {
      await AdmobStep().run(context(cfg: withUnits()));
      expect(adIds().readAsStringSync(), isNot(contains('rewardedHint')));
      await AdmobStep().run(context(cfg: withUnits('''
  ad_units:
    banner_main:
      type: banner
    rewarded_hint:
      type: rewarded
''')));
      final source = adIds().readAsStringSync();
      expect(source, contains('get bannerMain'));
      expect(source, contains('get rewardedHint'));
      // The rewarded test units, not the banner ones.
      expect(source, contains('ca-app-pub-3940256099942544/1712485313'));
    });

    test('a unit removed from the yaml loses its accessor', () async {
      await AdmobStep().run(context(cfg: withUnits('''
  ad_units:
    banner_main:
      type: banner
    rewarded_hint:
      type: rewarded
''')));
      await AdmobStep().run(context(cfg: withUnits()));
      final source = adIds().readAsStringSync();
      expect(source, contains('get bannerMain'));
      // Gone, so every call site fails to compile instead of going quiet.
      expect(source, isNot(contains('rewardedHint')));
    });

    test('declaring no units at all takes the file with them', () async {
      await AdmobStep().run(context(cfg: withUnits()));
      out.clear();
      await AdmobStep().run(context());
      expect(adIds().existsSync(), isFalse);
      expect(out.toString(), contains('no ad units declared'));
    });

    test('the seeded file is handed to the project formatter', () async {
      // Line breaks depend on the unit names, so the generator cannot lay
      // the file out the way the formatter would — and a file CI's
      // --set-exit-if-changed rejects is a bad thing to seed.
      final processes = _DartProcessRunner();
      await AdmobStep()
          .run(context(cfg: withUnits(), processes: processes));
      expect(processes.ran, hasLength(1));
      final (executable, arguments) = processes.ran.single;
      expect(executable, 'dart');
      // A scratch file inside the project, so it inherits the same formatter
      // settings — and gone again afterwards.
      expect(arguments.first, 'format');
      expect(p.dirname(arguments.last), p.join(tempDir.path, 'lib', 'ads'));
      expect(File(arguments.last).existsSync(), isFalse);
    });

    test('what the formatter leaves behind is what gets written', () async {
      // Formatting has to happen before the writeIfChanged comparison, or
      // every run would see a difference and rewrite.
      final processes = _DartProcessRunner(formatted: '// formatted\n');
      await AdmobStep().run(context(cfg: withUnits(), processes: processes));
      expect(adIds().readAsStringSync(), '// formatted\n');
    });

    test('a formatter that fails leaves the source as generated', () async {
      final processes = _DartProcessRunner(
        formatted: '// half written',
        exitCode: 1,
      );
      await AdmobStep().run(context(cfg: withUnits(), processes: processes));
      expect(adIds().readAsStringSync(), contains('get bannerMain'));
    });

    test('a broken dart binary does not take the run down', () async {
      final processes = _DartProcessRunner(throws: true);
      await AdmobStep().run(context(cfg: withUnits(), processes: processes));
      expect(adIds().readAsStringSync(), contains('get bannerMain'));
    });

    test('the scratch file is gone even when formatting throws', () async {
      await AdmobStep().run(
        context(cfg: withUnits(), processes: _DartProcessRunner(throws: true)),
      );
      final leftovers = Directory(p.join(tempDir.path, 'lib', 'ads'))
          .listSync()
          .map((entity) => p.basename(entity.path));
      expect(leftovers, ['ad_ids.dart']);
    });

    test('names that share a prefix do not collide', () async {
      // Class-level constants would have derived _bannerMainTestIos from
      // both of these, and the file would not compile.
      await AdmobStep().run(context(cfg: withUnits('''
  ad_units:
    banner_main:
      type: banner
    banner_main_test:
      type: banner
''')));
      final source = adIds().readAsStringSync();
      expect(source, contains('get bannerMain '));
      expect(source, contains('get bannerMainTest '));
      // Per-unit state is local to its getter, so nothing at class level
      // can clash; the getters themselves are unique because the yaml only
      // allows lower_snake_case.
      expect(source, isNot(contains('static const')));
      final getters = RegExp(r'get (\w+)')
          .allMatches(source)
          .map((match) => match.group(1))
          .toList();
      expect(getters, ['bannerMain', 'bannerMainTest']);
    });

    test('a scratch file an earlier run left behind is swept up', () async {
      final stale = File(
        p.join(tempDir.path, 'lib', 'ads', '${AdmobStep.scratchPrefix}99.dart'),
      )..createSync(recursive: true);
      await AdmobStep().run(
        context(cfg: withUnits(), processes: _DartProcessRunner()),
      );
      expect(stale.existsSync(), isFalse);
      expect(adIds().existsSync(), isTrue);
    });

    test('a file easy_setup did not write is never touched', () async {
      final file = adIds()
        ..createSync(recursive: true)
        ..writeAsStringSync('// mine, by hand\n');
      await AdmobStep().run(context(cfg: withUnits()));
      expect(file.readAsStringSync(), '// mine, by hand\n');
      expect(out.toString(), contains('was not written by easy_setup'));
    });

    test('a file easy_setup did not write is never deleted either', () async {
      final file = adIds()
        ..createSync(recursive: true)
        ..writeAsStringSync('// mine, by hand\n');
      // No ad_units at all — the branch that would otherwise converge.
      await AdmobStep().run(context());
      expect(file.existsSync(), isTrue);
    });

    test('no Dart SDK to format with is not an error', () async {
      // _NoToolProcessRunner finds nothing; the source is valid regardless.
      await AdmobStep().run(context(cfg: withUnits()));
      expect(adIds().existsSync(), isTrue);
    });

    test('dry-run writes nothing', () async {
      await AdmobStep().run(context(cfg: withUnits(), dryRun: true));
      expect(adIds().existsSync(), isFalse);
      expect(out.toString(), contains('Would write'));
    });

    test('dry-run does not delete an existing file either', () async {
      await AdmobStep().run(context(cfg: withUnits()));
      await AdmobStep().run(context(dryRun: true));
      expect(adIds().existsSync(), isTrue);
      expect(out.toString(), contains('Would delete'));
    });

    test('no units, no file', () async {
      await AdmobStep().run(context());
      expect(adIds().existsSync(), isFalse);
    });
  });

  group('AdmobStep API resolution', () {
    const matchedUnitIos = 'ca-app-pub-1234567890123456/3030303030';
    const matchedUnitAndroid = 'ca-app-pub-1234567890123456/4040404040';
    const createdIosAppId = 'ca-app-pub-1234567890123456~7777777777';
    const createdAndroidAppId = 'ca-app-pub-1234567890123456~8888888888';
    const createdUnitId = 'ca-app-pub-1234567890123456/9999999999';

    ProjectConfig configWithoutIds(String adUnits) =>
        ProjectConfig.fromYaml(loadYaml('app: { name: X, bundle_id: com.x }\n'
            'admob:\n$adUnits') as Map);

    /// A stand-in AdMob account holding [apps] and [adUnits]; creation either
    /// succeeds or answers 403 like a publisher without creation access.
    JsonResponse Function(String, Uri, Object?) admobApi({
      List<Map<String, Object?>> apps = const [],
      List<Map<String, Object?>> adUnits = const [],
      bool createDenied = false,
    }) =>
        (method, uri, body) {
          const denied = {
            'error': {'message': 'The caller does not have permission'},
          };
          if (uri.path.endsWith('/accounts')) {
            return JsonResponse(200, {
              'account': [
                {'name': 'accounts/pub-1234567890123456'},
              ],
            });
          }
          if (uri.path.endsWith('/apps')) {
            if (method != 'POST') return JsonResponse(200, {'apps': apps});
            if (createDenied) return JsonResponse(403, denied);
            final platform = (body as Map)['platform'];
            return JsonResponse(200, {
              'appId':
                  platform == 'IOS' ? createdIosAppId : createdAndroidAppId,
              'platform': platform,
              'manualAppInfo': {'displayName': 'X'},
            });
          }
          if (uri.path.endsWith('/adUnits')) {
            if (method != 'POST') {
              return JsonResponse(200, {'adUnits': adUnits});
            }
            if (createDenied) return JsonResponse(403, denied);
            final request = body as Map;
            return JsonResponse(200, {
              'adUnitId': createdUnitId,
              'appId': request['appId'],
              'displayName': request['displayName'],
              'adFormat': request['adFormat'],
            });
          }
          return JsonResponse(404, null);
        };

    Map<String, Object?> envJson(String name) =>
        json.decode(File(p.join(tempDir.path, name)).readAsStringSync())
            as Map<String, Object?>;

    /// easy_setup.yaml on disk, which --adopt edits in place.
    File writeConfig(String yaml) =>
        File(p.join(tempDir.path, 'easy_setup.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(yaml);

    Map<String, Object?> iosApp() => {
      'appId': _iosAppId,
      'platform': 'IOS',
      'manualAppInfo': {'displayName': 'X'},
    };

    test('a normal run names the ad units the yaml does not declare',
        () async {
      // The listing is already in hand for the lookup, so saying what else
      // is there costs nothing — and it is the only way to see it without
      // opening the console.
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'banner_main',
              'adFormat': 'BANNER',
            },
            {
              'adUnitId': 'ca-app-pub-1234567890123456/5050505050',
              'appId': _iosAppId,
              'displayName': 'rewarded_hint',
              'adFormat': 'REWARDED',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      final printed = out.toString();
      expect(printed, contains('1 ad unit(s) in AdMob are not declared here'));
      expect(printed, contains('rewarded_hint (REWARDED)'));
      expect(printed, contains('--adopt'));
      // The declared one is not in the list.
      expect(printed, isNot(contains('banner_main (BANNER)')));
    });

    test('a unit on both platforms is one line, not two', () async {
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [
            iosApp(),
            {
              'appId': _androidAppId,
              'platform': 'ANDROID',
              'linkedAppInfo': {'appStoreId': 'com.x'},
            },
          ],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'rewarded_hint',
              'adFormat': 'REWARDED',
            },
            {
              'adUnitId': matchedUnitAndroid,
              'appId': _androidAppId,
              'displayName': 'rewarded_hint',
              'adFormat': 'REWARDED',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      expect(out.toString(),
          contains('1 ad unit(s) in AdMob are not declared here'));
    });

    test('nothing is said when the yaml declares them all', () async {
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              // Matched by display_name, the same way the lookup matches.
              'displayName': 'Banner (main)',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds(
              '  ad_units:\n    banner_main:\n      display_name: Banner (main)\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      expect(out.toString(), isNot(contains('not declared here')));
    });

    test('another app\'s units are not this project\'s gap', () async {
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': 'ca-app-pub-1234567890123456~0000000000',
              'displayName': 'someone_elses',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      expect(out.toString(), isNot(contains('someone_elses')));
    });

    test('no app resolved, no ad unit listing', () async {
      // Nothing to match a unit against and nothing to report, so the run
      // costs the same two calls it did before the report existed.
      final http = FakeHttpJsonClient(
        admobApi(apps: const [], createDenied: true),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      expect(
        http.requests.where((r) => r.$2.path.endsWith('/adUnits')),
        isEmpty,
      );
    });

    test('an app with nothing left to resolve still gets the report',
        () async {
      // Unit IDs pinned, app ID not: the listing buys the report and
      // nothing else, and that is what it is for.
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': 'ca-app-pub-1234567890123456/5050505050',
              'appId': _iosAppId,
              'displayName': 'rewarded_hint',
              'adFormat': 'REWARDED',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'
              '      ios: ca-app-pub-1234567890123456/1111111111\n'
              '      android: ca-app-pub-1234567890123456/2222222222\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      expect(out.toString(), contains('rewarded_hint (REWARDED)'));
    });

    test('a declared name matches whatever case the console uses', () async {
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'Banner_Main',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      expect(out.toString(), isNot(contains('not declared here')));
    });

    test('the same unit named differently per platform is still one line',
        () async {
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [
            iosApp(),
            {
              'appId': _androidAppId,
              'platform': 'ANDROID',
              'linkedAppInfo': {'appStoreId': 'com.x'},
            },
          ],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'Rewarded Hint',
              'adFormat': 'REWARDED',
            },
            {
              'adUnitId': matchedUnitAndroid,
              'appId': _androidAppId,
              // Same unit, typed in with different capitalisation.
              'displayName': 'rewarded hint',
              'adFormat': 'REWARDED',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      expect(out.toString(),
          contains('1 ad unit(s) in AdMob are not declared here'));
    });

    test('a unit with no format and a blank one are handled', () async {
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'mystery_unit',
            },
            {
              'adUnitId': 'ca-app-pub-1234567890123456/7070707070',
              'appId': _iosAppId,
              'displayName': '   ',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      final printed = out.toString();
      // No format, no parentheses; the nameless one is not worth reporting.
      expect(printed, contains('      mystery_unit\n'));
      expect(printed, contains('1 ad unit(s) in AdMob are not declared here'));
    });

    test('a comma in a display name does not read as two units', () async {
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'Banner, bottom',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      final printed = out.toString();
      expect(printed, contains('1 ad unit(s) in AdMob are not declared here'));
      expect(printed, contains('      Banner, bottom (BANNER)\n'));
    });

    test('a wrong-format unit is reported by the lookup, not twice',
        () async {
      // _resolveAdUnits already says the format does not match, in more
      // detail than "not declared" could; a second line would be noise.
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'banner_main',
              'adFormat': 'REWARDED',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  ad_units:\n    banner_main:\n'
              '      type: banner\n'),
          http: http,
          env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        ),
      );
      final printed = out.toString();
      expect(printed, contains('is a REWARDED unit'));
      expect(printed, isNot(contains('not declared here')));
    });

    test('--adopt writes the console ad units into easy_setup.yaml', () async {
      final file = writeConfig('''
app: { name: X, bundle_id: com.x }
admob:
  ad_units:
    banner_main:
      type: banner
''');
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'banner_main',
              'adFormat': 'BANNER',
            },
            {
              'adUnitId': 'ca-app-pub-1234567890123456/5050505050',
              'appId': _iosAppId,
              'displayName': 'rewarded_hint',
              'adFormat': 'REWARDED',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
            http: http,
            adopt: true, env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      // Declared already, so only the new one is added — with its format.
      expect(file.readAsStringSync(), '''
app: { name: X, bundle_id: com.x }
admob:
  ad_units:
    banner_main:
      type: banner
    rewarded_hint:
      type: rewarded
''');
      expect(out.toString(), contains('Added rewarded_hint'));
      // And the run uses it straight away.
      expect(envJson('env.prod.json')['ADMOB_REWARDED_HINT_IOS'],
          'ca-app-pub-1234567890123456/5050505050');
    });

    test('--adopt keeps a console name the yaml key cannot carry', () async {
      final file = writeConfig('''
app: { name: X, bundle_id: com.x }
admob:
  ad_units:
''');
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'Banner (main)',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n'), http: http,
            adopt: true, env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      final written = file.readAsStringSync();
      expect(written, contains('    banner_main:'));
      expect(written, contains('      display_name: Banner (main)'));
    });

    test('--adopt says so when a name has nothing usable in it', () async {
      writeConfig('app: { name: X, bundle_id: com.x }\nadmob:\n  ad_units:\n');
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': '배너 (메인)',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n'), http: http,
            adopt: true, env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      expect(out.toString(), contains('Cannot name "배너 (메인)"'));
    });

    test('--adopt adds nothing when the yaml already has it all', () async {
      writeConfig('app: { name: X, bundle_id: com.x }\nadmob:\n'
          '  ad_units:\n    banner_main:\n      type: banner\n');
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'banner_main',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n    banner_main:\n'),
            http: http,
            adopt: true, env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      expect(out.toString(), contains('Nothing to adopt'));
    });

    test('--adopt ignores ad units belonging to another app', () async {
      final file = writeConfig(
          'app: { name: X, bundle_id: com.x }\nadmob:\n  ad_units:\n');
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': 'ca-app-pub-1234567890123456~0000000000',
              'displayName': 'someone_elses',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n'), http: http,
            adopt: true, env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      expect(file.readAsStringSync(), isNot(contains('someone_elses')));
    });

    test('--adopt refuses two console names that slug the same', () async {
      // Writing both would leave a duplicate key, and one of the two would
      // vanish on the next parse.
      final file = writeConfig(
          'app: { name: X, bundle_id: com.x }\nadmob:\n  ad_units:\n');
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'Banner Main',
              'adFormat': 'BANNER',
            },
            {
              'adUnitId': 'ca-app-pub-1234567890123456/6060606060',
              'appId': _iosAppId,
              'displayName': 'Banner-main',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n'), http: http,
            adopt: true, env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      final written = file.readAsStringSync();
      expect('banner_main:'.allMatches(written).length, 1);
      expect(out.toString(), contains('Cannot name "Banner-main"'));
    });

    test('--adopt refuses a name the parser would reject', () async {
      final file = writeConfig(
          'app: { name: X, bundle_id: com.x }\nadmob:\n  ad_units:\n');
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              // A Dart reserved word: valid as a slug, fatal as an accessor.
              'displayName': 'class',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n'), http: http,
            adopt: true, env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      expect(file.readAsStringSync(), isNot(contains('class:')));
      expect(out.toString(), contains('Cannot name "class"'));
    });

    test('--adopt quotes a display name that would not survive', () async {
      final file = writeConfig(
          'app: { name: X, bundle_id: com.x }\nadmob:\n  ad_units:\n');
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              // Unquoted, YAML reads this back as 'Banner'.
              'displayName': 'Banner #1',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n'), http: http,
            adopt: true, env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      final written = file.readAsStringSync();
      expect(written, contains("display_name: 'Banner #1'"));
      // And it parses back to what the console actually has.
      final reparsed = ProjectConfig.fromYaml(loadYaml(written) as Map);
      expect(reparsed.admob!.adUnits['banner_1']!.displayName, 'Banner #1');
    });

    test('--adopt with auto off has nothing to read', () async {
      await AdmobStep().run(
        context(
          cfg: configWithoutIds('  auto: false\n  ad_units:\n'),
          adopt: true,
        ),
      );
      expect(out.toString(), contains('admob.auto is off'));
    });

    test('--adopt under dry-run touches no file', () async {
      final file = writeConfig(
          'app: { name: X, bundle_id: com.x }\nadmob:\n  ad_units:\n');
      final before = file.readAsStringSync();
      final http = FakeHttpJsonClient(
        admobApi(
          apps: [iosApp()],
          adUnits: [
            {
              'adUnitId': matchedUnitIos,
              'appId': _iosAppId,
              'displayName': 'banner_main',
              'adFormat': 'BANNER',
            },
          ],
        ),
      );
      await AdmobStep().run(
        context(cfg: configWithoutIds('  ad_units:\n'), http: http,
            adopt: true, dryRun: true,
            env: const {'ADMOB_ACCESS_TOKEN': 'token'}),
      );
      expect(file.readAsStringSync(), before);
      // --dry-run promises no API was touched, and reading an account is a
      // real call.
      expect(http.requests, isEmpty);
      expect(out.toString(), contains('Would read the AdMob account'));
    });

    test('matches the existing app and ad unit instead of asking for IDs',
        () async {
      final http = FakeHttpJsonClient(admobApi(
        apps: [
          {
            'appId': _iosAppId,
            'platform': 'IOS',
            'manualAppInfo': {'displayName': 'X'},
          },
          {
            'appId': _androidAppId,
            'platform': 'ANDROID',
            // Android links by package name, which the config knows.
            'linkedAppInfo': {'appStoreId': 'com.x'},
          },
        ],
        adUnits: [
          {
            'adUnitId': matchedUnitIos,
            'appId': _iosAppId,
            'displayName': 'banner_main',
            'adFormat': 'BANNER',
          },
          {
            'adUnitId': matchedUnitAndroid,
            'appId': _androidAppId,
            'displayName': 'banner_main',
            'adFormat': 'BANNER',
          },
        ],
      ));
      await AdmobStep().run(context(
        cfg: configWithoutIds('  ad_units:\n    banner_main: { type: banner }'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));

      expect(manifestFile.readAsStringSync(), contains(_androidAppId));
      expect(plistFile.readAsStringSync(), contains(_iosAppId));
      expect(envJson('env.prod.json')['ADMOB_BANNER_MAIN_IOS'], matchedUnitIos);
      expect(envJson('env.prod.json')['ADMOB_BANNER_MAIN_ANDROID'],
          matchedUnitAndroid);
      // Nothing was created — everything already existed.
      expect(http.requests.where((r) => r.$1 == 'POST'), isEmpty);
    });

    test('creates the app and the ad unit when the account may', () async {
      final http = FakeHttpJsonClient(admobApi());
      await AdmobStep().run(context(
        cfg: configWithoutIds(
            '  ad_units:\n    rewarded_hint: { type: rewarded }'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));

      final created = http.requests.where((r) => r.$1 == 'POST').toList();
      expect(created, hasLength(4)); // two apps + two ad units
      final unitRequest =
          created.firstWhere((r) => r.$2.path.endsWith('/adUnits')).$3 as Map;
      expect(unitRequest['adFormat'], 'REWARDED');
      expect(unitRequest['adTypes'], ['RICH_MEDIA', 'VIDEO']);
      expect(unitRequest['displayName'], 'rewarded_hint');

      expect(plistFile.readAsStringSync(), contains(createdIosAppId));
      expect(manifestFile.readAsStringSync(), contains(createdAndroidAppId));
      expect(
          envJson('env.prod.json')['ADMOB_REWARDED_HINT_IOS'], createdUnitId);
    });

    test('a 403 on create degrades to console guidance', () async {
      final http = FakeHttpJsonClient(admobApi(createDenied: true));
      await AdmobStep().run(context(
        cfg: configWithoutIds('  ad_units:\n    banner_main: { type: banner }'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));
      expect(out.toString(), contains('limited access'));
      expect(out.toString(), contains('No ios app ID'));
      // Nothing to inject, so the native files are untouched.
      expect(manifestFile.readAsStringSync(), _manifest);
      expect(plistFile.readAsStringSync(), _infoPlist);
    });

    test('declared IDs win — the API is never called', () async {
      final http = FakeHttpJsonClient(admobApi());
      await AdmobStep().run(context(
        cfg: config('  ad_units:\n'
            '    banner_main:\n'
            '      type: banner\n'
            '      ios: ca-app-pub-1234567890123456/1010101010\n'
            '      android: ca-app-pub-1234567890123456/2020202020\n'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));
      expect(http.requests, isEmpty);
    });

    test('auto: false keeps setup offline', () async {
      final http = FakeHttpJsonClient(admobApi());
      await AdmobStep().run(context(
        cfg: configWithoutIds(
            '  auto: false\n  ad_units:\n    banner_main: { type: banner }'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));
      expect(http.requests, isEmpty);
      expect(out.toString(), contains('No ios app ID'));
    });

    test('auto: false prunes a platform ID the yaml dropped', () async {
      File(p.join(tempDir.path, 'env.prod.json')).writeAsStringSync(
          '{"ADMOB_BANNER_MAIN_IOS": "ca-app-pub-1/1", '
          '"ADMOB_BANNER_MAIN_ANDROID": "ca-app-pub-1/2"}');
      await AdmobStep().run(context(
        cfg: configWithoutIds('  auto: false\n'
            '  ad_units:\n'
            '    banner_main: { type: banner, '
            'android: ca-app-pub-1234567890123456/2020202020 }'),
        http: FakeHttpJsonClient(admobApi()),
      ));
      final env = envJson('env.prod.json');
      // iOS is gone from the yaml and nothing can look it up any more.
      expect(env.containsKey('ADMOB_BANNER_MAIN_IOS'), isFalse);
      expect(env['ADMOB_BANNER_MAIN_ANDROID'],
          'ca-app-pub-1234567890123456/2020202020');
    });

    test('an ad unit without a type says what to declare', () async {
      final http = FakeHttpJsonClient(admobApi(
        apps: [
          {
            'appId': _iosAppId,
            'platform': 'IOS',
            'manualAppInfo': {'displayName': 'X'},
          },
        ],
      ));
      await AdmobStep().run(context(
        cfg: configWithoutIds('  ad_units:\n    banner_main: {}'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));
      expect(
          out.toString(), contains('declare admob.ad_units.banner_main.type'));
      // No unit is created without a format to create it with.
      expect(
          http.requests
              .where((r) => r.$1 == 'POST' && r.$2.path.endsWith('/adUnits')),
          isEmpty);
    });

    test('a display_name overrides what the lookup matches on', () async {
      final http = FakeHttpJsonClient(admobApi(
        apps: [
          {
            'appId': _iosAppId,
            'platform': 'IOS',
            'manualAppInfo': {'displayName': 'X'},
          },
        ],
        adUnits: [
          {
            'adUnitId': matchedUnitIos,
            'appId': _iosAppId,
            'displayName': 'Banner (main)',
            'adFormat': 'BANNER',
          },
        ],
      ));
      await AdmobStep().run(context(
        cfg: configWithoutIds('  ad_units:\n'
            '    banner_main: { type: banner, display_name: Banner (main) }'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));
      expect(envJson('env.prod.json')['ADMOB_BANNER_MAIN_IOS'], matchedUnitIos);
    });

    test('the package name outranks a same-named Android app', () async {
      const otherAppId = 'ca-app-pub-1234567890123456~5555555555';
      final http = FakeHttpJsonClient(admobApi(
        apps: [
          // Listed first, same name, but a different app.
          {
            'appId': otherAppId,
            'platform': 'ANDROID',
            'manualAppInfo': {'displayName': 'X'},
          },
          {
            'appId': _androidAppId,
            'platform': 'ANDROID',
            'linkedAppInfo': {'appStoreId': 'com.x', 'displayName': 'X'},
          },
        ],
      ));
      await AdmobStep().run(context(
        cfg: configWithoutIds('  ad_units: {}'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));
      expect(manifestFile.readAsStringSync(), contains(_androidAppId));
      expect(manifestFile.readAsStringSync(), isNot(contains(otherAppId)));
    });

    test('a same-named unit of another format is reported, not adopted',
        () async {
      final http = FakeHttpJsonClient(admobApi(
        apps: [
          {
            'appId': _iosAppId,
            'platform': 'IOS',
            'manualAppInfo': {'displayName': 'X'},
          },
        ],
        adUnits: [
          {
            'adUnitId': matchedUnitIos,
            'appId': _iosAppId,
            'displayName': 'promo_slot',
            'adFormat': 'BANNER',
          },
        ],
      ));
      await AdmobStep().run(context(
        cfg: configWithoutIds(
            '  ad_units:\n    promo_slot: { type: rewarded }'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));
      expect(out.toString(), contains('is a BANNER unit'));
      final env = File(p.join(tempDir.path, 'env.prod.json'));
      expect(
          env.existsSync() ? env.readAsStringSync() : '{}',
          isNot(contains(matchedUnitIos)));
    });

    test('a rejected format mismatch drops the stale ID it replaced',
        () async {
      File(p.join(tempDir.path, 'env.prod.json')).writeAsStringSync(
          '{"ADMOB_PROMO_SLOT_IOS": "$matchedUnitIos"}');
      final http = FakeHttpJsonClient(admobApi(
        apps: [
          {
            'appId': _iosAppId,
            'platform': 'IOS',
            'manualAppInfo': {'displayName': 'X'},
          },
        ],
        adUnits: [
          {
            'adUnitId': matchedUnitIos,
            'appId': _iosAppId,
            'displayName': 'promo_slot',
            'adFormat': 'BANNER',
          },
        ],
      ));
      await AdmobStep().run(context(
        cfg: configWithoutIds(
            '  ad_units:\n    promo_slot: { type: rewarded }'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
      ));
      // The banner ID must not stay behind for a rewarded placement.
      expect(envJson('env.prod.json').containsKey('ADMOB_PROMO_SLOT_IOS'),
          isFalse);
    });

    test('IDs from an earlier run survive a failed lookup', () async {
      final matching = admobApi(
        apps: [
          {
            'appId': _iosAppId,
            'platform': 'IOS',
            'manualAppInfo': {'displayName': 'X'},
          },
        ],
        adUnits: [
          {
            'adUnitId': matchedUnitIos,
            'appId': _iosAppId,
            'displayName': 'banner_main',
            'adFormat': 'BANNER',
          },
        ],
      );
      final cfg =
          configWithoutIds('  ad_units:\n    banner_main: { type: banner }');
      await AdmobStep().run(context(
        cfg: cfg,
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: FakeHttpJsonClient(matching),
      ));
      expect(envJson('env.prod.json')['ADMOB_BANNER_MAIN_IOS'], matchedUnitIos);

      // Second run: the credential is gone, so nothing resolves. The IDs the
      // app ships with must not be wiped.
      await AdmobStep().run(context(
        cfg: cfg,
        http: FakeHttpJsonClient(matching),
      ));
      expect(envJson('env.prod.json')['ADMOB_BANNER_MAIN_IOS'], matchedUnitIos);
      expect(out.toString(), contains('AdMob lookup skipped'));
    });

    test('a unit dropped from the yaml still loses its keys', () async {
      final http = FakeHttpJsonClient(admobApi());
      File(p.join(tempDir.path, 'env.prod.json')).writeAsStringSync(
          '{"ADMOB_GONE_IOS": "ca-app-pub-1/1", '
          '"ADMOB_BANNER_MAIN_IOS": "ca-app-pub-1/2"}');
      await AdmobStep().run(context(
        cfg: configWithoutIds('  ad_units:\n    banner_main: { type: banner }'),
        http: http,
      ));
      final env = envJson('env.prod.json');
      expect(env.containsKey('ADMOB_GONE_IOS'), isFalse);
      expect(env['ADMOB_BANNER_MAIN_IOS'], 'ca-app-pub-1/2');
    });

    test('dry-run makes no API calls', () async {
      final http = FakeHttpJsonClient(admobApi());
      await AdmobStep().run(context(
        cfg: configWithoutIds('  ad_units:\n    banner_main: { type: banner }'),
        env: const {'ADMOB_ACCESS_TOKEN': 'token'},
        http: http,
        dryRun: true,
      ));
      expect(http.requests, isEmpty);
      expect(out.toString(), contains('[dry-run]'));
    });
  });
}
