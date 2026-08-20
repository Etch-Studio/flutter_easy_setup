import 'package:easy_setup/easy_setup.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

ProjectConfig parse(String yaml) =>
    ProjectConfig.fromYaml(loadYaml(yaml) as Map);

void main() {
  group('ProjectConfig.fromYaml', () {
    test('parses a full v2 config', () {
      final config = parse('''
app:
  name: MyApp
  bundle_id: com.example.myapp
  package_name: com.example.myapp.android

ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
  capabilities:
    - push_notifications
    - app_groups: [group.com.example.myapp]
  background_modes: [audio, fetch]

android:
  play_track_default: beta

flavors:
  dev: { suffix: .dev, name: MyApp DEV }
  prod: {}

branding:
  icon_src: assets/branding/icon/

screenshots:
  locales: [ko, en-US]
  devices: [iphone_6_9, ipad_13]

sentry:
  org: my-org
  project: myapp

firebase:
  project_id: my-org-myapp
  analytics: true

admob:
  ios_app_id: ca-app-pub-1234567890123456~1234567890
  android_app_id: ca-app-pub-1234567890123456~0987654321
  ad_units:
    banner_main:
      ios: ca-app-pub-1234567890123456/1111111111
      android: ca-app-pub-1234567890123456/2222222222
''');

      expect(config.app.name, 'MyApp');
      expect(config.app.bundleId, 'com.example.myapp');
      expect(config.app.packageName, 'com.example.myapp.android');

      final ios = config.ios!;
      expect(ios.teamId, 'ABCDE12345');
      expect(ios.matchGitUrl, 'git@github.com:org/certs.git');
      expect(ios.capabilities, hasLength(2));
      expect(ios.capabilities[0].name, 'push_notifications');
      expect(ios.capabilities[0].parameters, isEmpty);
      expect(ios.capabilities[1].name, 'app_groups');
      expect(ios.capabilities[1].parameters, ['group.com.example.myapp']);
      expect(ios.backgroundModes, ['audio', 'fetch']);

      expect(config.android!.playTrackDefault, 'beta');

      expect(config.flavors.keys, ['dev', 'prod']);
      expect(config.flavors['dev']!.suffix, '.dev');
      expect(config.flavors['dev']!.name, 'MyApp DEV');
      expect(config.flavors['prod']!.suffix, isNull);

      expect(config.branding!.iconSrc, 'assets/branding/icon/');
      expect(config.screenshots!.locales, ['ko', 'en-US']);
      expect(config.screenshots!.devices, ['iphone_6_9', 'ipad_13']);
      expect(config.sentry!.org, 'my-org');
      expect(config.sentry!.project, 'myapp');
      expect(config.firebase!.projectId, 'my-org-myapp');
      expect(config.firebase!.analytics, isTrue);
      expect(config.admob!.iosAppId, 'ca-app-pub-1234567890123456~1234567890');
      expect(config.admob!.adUnits['banner_main']!.ios,
          'ca-app-pub-1234567890123456/1111111111');
    });

    test('parses a minimal config (app only) with package_name fallback', () {
      final config = parse('''
app:
  name: Tiny
  bundle_id: com.example.tiny
''');
      expect(config.app.packageName, 'com.example.tiny');
      expect(config.ios, isNull);
      expect(config.android, isNull);
      expect(config.flavors, isEmpty);
      expect(config.sentry, isNull);
    });

    test('bare optional sections enable the section with defaults', () {
      final config = parse('''
app:
  name: Tiny
  bundle_id: com.example.tiny
ios:
android:
''');
      expect(config.ios, isNotNull);
      expect(config.ios!.capabilities, isEmpty);
      expect(config.android, isNotNull);
      expect(config.android!.playTrackDefault, 'internal');
    });

    test('bundle_id falls back to package_name', () {
      final config = parse('''
app:
  name: Tiny
  package_name: com.example.droid
''');
      expect(config.app.bundleId, 'com.example.droid');
    });

    test('rejects a config without app section', () {
      expect(
        () => parse('ios:\n  team_id: ABCDE12345\n'),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains("'app' is missing"))),
      );
    });

    test('rejects app without name', () {
      expect(
        () => parse('app:\n  bundle_id: com.example.x\n'),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains("'app.name'"))),
      );
    });

    test('rejects app without any identifier', () {
      expect(
        () => parse('app:\n  name: X\n'),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('bundle_id'))),
      );
    });

    test('detects the v1 schema and points to migration', () {
      expect(
        () => parse('easy_setup:\n  flavors:\n    dev:\n'),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('v1 schema'))),
      );
    });

    test('rejects an invalid play track', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
android: { play_track_default: nightly }
'''),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('play_track_default'))),
      );
    });

    test('rejects an unknown screenshot device', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
screenshots: { devices: [iphone_15] }
'''),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains("'iphone_15'"))),
      );
    });

    test('rejects a multi-key capability entry', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
ios:
  capabilities:
    - app_groups: [g1]
      push_notifications: []
'''),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('single-key'))),
      );
    });

    test('rejects non-bool firebase.analytics', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
firebase: { analytics: yes please }
'''),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('firebase.analytics'))),
      );
    });

    test('rejects sentry section without org', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
sentry: { project: myapp }
'''),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains("'sentry.org'"))),
      );
    });
  });

  group('BuildConfig', () {
    test('absent by default, and env.prod.json is the fallback name', () {
      expect(parse('app: { name: X, bundle_id: com.x }').build, isNull);
      expect(BuildConfig.defaultDartDefineFile, 'env.prod.json');
    });

    test('dart_define_file is read', () {
      final build = parse('''
app: { name: X, bundle_id: com.x }
build: { dart_define_file: env.store.json }
''').build!;
      expect(build.dartDefineFile, 'env.store.json');
    });
  });

  group('AmplitudeConfig', () {
    test('a bare section takes every default', () {
      final amplitude = parse('''
app: { name: X, bundle_id: com.x }
amplitude:
''').amplitude!;
      expect(amplitude.apiKeyEnv, 'AMPLITUDE_API_KEY');
      expect(amplitude.devApiKeyEnv, 'AMPLITUDE_DEV_API_KEY');
      expect(amplitude.region, 'us');
      expect(amplitude.verify, isTrue);
      expect(amplitude.sdk, isTrue);
      expect(amplitude.ingestionUrl, 'https://api2.amplitude.com/2/httpapi');
    });

    test('every field can be overridden', () {
      final amplitude = parse('''
app: { name: X, bundle_id: com.x }
amplitude:
  project: dream-diary
  api_key_env: DIARY_KEY
  dev_api_key_env: DIARY_DEV_KEY
  region: EU
  verify: false
  sdk: false
''').amplitude!;
      expect(amplitude.project, 'dream-diary');
      expect(amplitude.apiKeyEnv, 'DIARY_KEY');
      expect(amplitude.devApiKeyEnv, 'DIARY_DEV_KEY');
      // The region is case-insensitive; the EU host follows from it.
      expect(amplitude.region, 'eu');
      expect(amplitude.ingestionUrl, 'https://api.eu.amplitude.com/2/httpapi');
      expect(amplitude.verify, isFalse);
      expect(amplitude.sdk, isFalse);
    });

    test('an unknown region names the allowed ones', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
amplitude: { region: apac }
'''),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('us | eu'))),
      );
    });

    test('a non-boolean flag is rejected at parse time', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
amplitude: { verify: yes-please }
'''),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('must be true or false'))),
      );
    });
  });

  group('SentryConfig wiring flags', () {
    test('the SDK and symbol upload are on by default', () {
      final sentry = parse('''
app: { name: X, bundle_id: com.x }
sentry: { org: my-org }
''').sentry!;
      expect(sentry.sdk, isTrue);
      expect(sentry.uploadSymbols, isTrue);
    });

    test('both can be turned off', () {
      final sentry = parse('''
app: { name: X, bundle_id: com.x }
sentry: { org: my-org, sdk: false, upload_symbols: false }
''').sentry!;
      expect(sentry.sdk, isFalse);
      expect(sentry.uploadSymbols, isFalse);
    });
  });

  group('AdmobConfig lookup fields', () {
    test('auto is on and the publisher ID is optional', () {
      final admob = parse('''
app: { name: X, bundle_id: com.x }
admob:
  ad_units:
    banner_main: { type: banner, display_name: Banner (main) }
''').admob!;
      expect(admob.auto, isTrue);
      expect(admob.publisherId, isNull);
      expect(admob.adUnits['banner_main']!.displayName, 'Banner (main)');
    });

    test('an ad unit name has to survive both translations', () {
      // The name becomes ADMOB_<NAME>_<PLATFORM> and a Dart accessor in the
      // generated lib/ads/ad_ids.dart, so anything that is not
      // lower_snake_case breaks one of the two — silently, at the far end.
      for (final name in [
        'Banner_Main',
        'rewarded-hint',
        '2nd_banner',
        '_private',
        'banner__main',
        r"broken'quote",
        r'dollar$sign',
      ]) {
        expect(
          () => parse('''
app: { name: X, bundle_id: com.x }
admob:
  ad_units:
    $name: { type: banner }
'''),
          throwsA(
            isA<SetupException>().having(
              (e) => e.message,
              'message for "$name"',
              contains('lower_snake_case'),
            ),
          ),
          reason: name,
        );
      }
    });

    test('a Dart reserved word cannot become an accessor', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
admob:
  ad_units:
    class: { type: banner }
'''),
        throwsA(
          isA<SetupException>().having(
            (e) => e.message,
            'message',
            contains('reserved word'),
          ),
        ),
      );
    });

    test('a publisher ID must look like one', () {
      expect(
        () => parse('''
app: { name: X, bundle_id: com.x }
admob: { publisher_id: 1234567890123456 }
'''),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            contains('pub-1234567890123456'))),
      );
    });

    test('auto can be turned off to keep setup offline', () {
      final admob = parse('''
app: { name: X, bundle_id: com.x }
admob: { auto: false, publisher_id: pub-1234567890123456 }
''').admob!;
      expect(admob.auto, isFalse);
      expect(admob.publisherId, 'pub-1234567890123456');
    });
  });
}
