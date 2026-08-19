import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Fake ProcessRunner backed by a command → version-line map.
class FakeProcessRunner extends ProcessRunner {
  final Map<String, String> installed;

  /// Whether `gcloud auth application-default print-access-token` succeeds.
  final bool gcloudLoggedIn;

  const FakeProcessRunner(this.installed, {this.gcloudLoggedIn = true});

  @override
  Future<String?> which(String command) async =>
      installed.containsKey(command) ? '/usr/bin/$command' : null;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      gcloudLoggedIn
          ? ProcessResult(0, 0, 'ya29.token\n', '')
          : ProcessResult(0, 1, '',
              'ERROR: Could not automatically determine credentials.');

  @override
  Future<String?> versionOf(
    String command, {
    List<String> arguments = const ['--version'],
    Pattern? linePattern,
  }) async =>
      installed[command];
}

ProjectConfig config(String yaml) =>
    ProjectConfig.fromYaml(loadYaml(yaml) as Map);

DoctorContext context({
  String? projectRoot = '/project',
  ProjectConfig? cfg,
  SetupException? configError,
  bool? configFileExists,
  Map<String, String> env = const {},
  Map<String, String> installed = const {},
  bool gcloudLoggedIn = true,
}) =>
    DoctorContext(
      projectRoot: projectRoot,
      config: cfg,
      configError: configError,
      configFileExists: configFileExists ?? (cfg != null || configError != null),
      env: env,
      processes:
          FakeProcessRunner(installed, gcloudLoggedIn: gcloudLoggedIn),
      isMacOS: true,
    );

final iosConfig = config('''
app: { name: X, bundle_id: com.x }
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
''');

void main() {
  group('ToolCheck', () {
    final check = ToolCheck(
      title: 'Flutter SDK',
      command: 'flutter',
      fix: 'install flutter',
    );

    test('reports ok with version when installed', () async {
      final result = await check
          .run(context(installed: {'flutter': 'Flutter 3.35.0 • stable'}));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('3.35.0'));
    });

    test('reports error with fix when missing', () async {
      final result = await check.run(context());
      expect(result.status, CheckStatus.error);
      expect(result.fix, 'install flutter');
    });

    test('optional tool reports warning when missing', () async {
      final optional = ToolCheck(
        title: 'Fastlane',
        command: 'fastlane',
        fix: 'brew install fastlane',
        optional: true,
      );
      final result = await optional.run(context());
      expect(result.status, CheckStatus.warning);
    });
  });

  group('FlutterProjectCheck', () {
    test('errors outside a Flutter project', () async {
      final result = await FlutterProjectCheck().run(context(projectRoot: null));
      expect(result.status, CheckStatus.error);
      expect(result.fix, contains('--project-root'));
    });

    test('ok inside a project', () async {
      final result = await FlutterProjectCheck().run(context());
      expect(result.status, CheckStatus.ok);
      expect(result.detail, '/project');
    });
  });

  group('ConfigFileCheck', () {
    test('errors with init guidance when file is missing', () async {
      final result =
          await ConfigFileCheck().run(context(configFileExists: false));
      expect(result.status, CheckStatus.error);
      expect(result.fix, contains('easy_setup init'));
    });

    test('surfaces parse errors (v1 migration message)', () async {
      final result = await ConfigFileCheck().run(context(
        configError: SetupException('This easy_setup.yaml uses the v1 schema'),
      ));
      expect(result.status, CheckStatus.error);
      expect(result.fix, contains('v1 schema'));
    });

    test('ok with section summary when valid', () async {
      final result = await ConfigFileCheck().run(context(cfg: iosConfig));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('app: X'));
      expect(result.detail, contains('ios'));
    });
  });

  group('AscApiKeyCheck', () {
    test('skips when ios section is not configured', () async {
      final result = await AscApiKeyCheck()
          .run(context(cfg: config('app: { name: X, bundle_id: com.x }')));
      expect(result.status, CheckStatus.skipped);
    });

    test('lists all missing env vars with issue guidance', () async {
      final result = await AscApiKeyCheck().run(context(cfg: iosConfig));
      expect(result.status, CheckStatus.error);
      expect(result.detail, contains('ASC_KEY_ID'));
      expect(result.detail, contains('ASC_ISSUER_ID'));
      expect(result.detail, contains('ASC_KEY_P8'));
      expect(result.fix, contains('App Store Connect'));
    });

    test('ok when key id, issuer id, and p8 contents are set', () async {
      final result = await AscApiKeyCheck().run(context(cfg: iosConfig, env: {
        'ASC_KEY_ID': 'KEY123',
        'ASC_ISSUER_ID': 'issuer-uuid',
        'ASC_KEY_P8': '-----BEGIN PRIVATE KEY-----',
      }));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('KEY123'));
    });

    test('raw ASC_KEY_P8 wins over a stale ASC_KEY_P8_PATH', () async {
      final result = await AscApiKeyCheck().run(context(cfg: iosConfig, env: {
        'ASC_KEY_ID': 'KEY123',
        'ASC_ISSUER_ID': 'issuer-uuid',
        'ASC_KEY_P8': '-----BEGIN PRIVATE KEY-----',
        'ASC_KEY_P8_PATH': '/nonexistent/AuthKey.p8',
      }));
      expect(result.status, CheckStatus.ok);
    });

    test('errors when ASC_KEY_P8_PATH points to a missing file', () async {
      final result = await AscApiKeyCheck().run(context(cfg: iosConfig, env: {
        'ASC_KEY_ID': 'KEY123',
        'ASC_ISSUER_ID': 'issuer-uuid',
        'ASC_KEY_P8_PATH': '/nonexistent/AuthKey.p8',
      }));
      expect(result.status, CheckStatus.error);
      expect(result.detail, contains('missing file'));
    });
  });

  group('TeamIdCheck', () {
    test('warns when team_id is not set', () async {
      final result = await TeamIdCheck().run(context(
          cfg: config('app: { name: X, bundle_id: com.x }\nios: {}')));
      expect(result.status, CheckStatus.warning);
      expect(result.fix, contains('developer.apple.com'));
    });

    test('warns on a malformed team_id', () async {
      final result = await TeamIdCheck().run(context(
          cfg: config(
              'app: { name: X, bundle_id: com.x }\nios: { team_id: short }')));
      expect(result.status, CheckStatus.warning);
    });

    test('ok on a valid team_id', () async {
      final result = await TeamIdCheck().run(context(cfg: iosConfig));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, 'ABCDE12345');
    });
  });

  group('MatchCheck', () {
    test('errors when MATCH_PASSWORD is missing', () async {
      final result = await MatchCheck().run(context(cfg: iosConfig));
      expect(result.status, CheckStatus.error);
      expect(result.detail, contains('MATCH_PASSWORD'));
    });

    test('ok when repo and password are configured', () async {
      final result = await MatchCheck()
          .run(context(cfg: iosConfig, env: {'MATCH_PASSWORD': 'secret'}));
      expect(result.status, CheckStatus.ok);
    });
  });

  group('PlayServiceAccountCheck', () {
    final androidConfig = config('''
app: { name: X, bundle_id: com.x }
android: { play_track_default: internal }
''');

    test('errors when android is configured and env is missing', () async {
      final result =
          await PlayServiceAccountCheck().run(context(cfg: androidConfig));
      expect(result.status, CheckStatus.error);
      expect(result.detail, contains('PLAY_SERVICE_ACCOUNT_JSON'));
    });

    test('only warns when android is not configured', () async {
      final result = await PlayServiceAccountCheck()
          .run(context(cfg: config('app: { name: X, bundle_id: com.x }')));
      expect(result.status, CheckStatus.warning);
    });

    test('ok with raw service account JSON', () async {
      final result = await PlayServiceAccountCheck().run(context(
        cfg: androidConfig,
        env: {
          'PLAY_SERVICE_ACCOUNT_JSON':
              '{"client_email": "ci@project.iam.gserviceaccount.com"}',
        },
      ));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('ci@project'));
    });

    test('errors on JSON without client_email', () async {
      final result = await PlayServiceAccountCheck().run(context(
        cfg: androidConfig,
        env: {'PLAY_SERVICE_ACCOUNT_JSON': '{"type": "user"}'},
      ));
      expect(result.status, CheckStatus.error);
    });
  });

  group('SentryTokenCheck', () {
    final sentryConfig = config('''
app: { name: X, bundle_id: com.x }
sentry: { org: my-org }
''');

    test('skips when sentry is not configured', () async {
      final result = await SentryTokenCheck()
          .run(context(cfg: config('app: { name: X, bundle_id: com.x }')));
      expect(result.status, CheckStatus.skipped);
    });

    test('errors when the token is missing', () async {
      final result = await SentryTokenCheck().run(context(cfg: sentryConfig));
      expect(result.status, CheckStatus.error);
      expect(result.detail, contains('SENTRY_API_TOKEN'));
      expect(result.fix, contains('project:write'));
    });

    test('warns on an organization token — it cannot create projects',
        () async {
      final result = await SentryTokenCheck().run(context(
          cfg: sentryConfig, env: {'SENTRY_API_TOKEN': 'sntrys_abc'}));
      expect(result.status, CheckStatus.warning);
      expect(result.detail, contains('organization token'));
      expect(result.fix, contains('Internal Integration'));
    });

    test('ok on an internal integration or personal token', () async {
      final result = await SentryTokenCheck().run(context(
          cfg: sentryConfig, env: {'SENTRY_API_TOKEN': 'sntryu_abc'}));
      expect(result.status, CheckStatus.ok);
    });

    test('the legacy SENTRY_ORG_TOKEN name still counts, and says so',
        () async {
      final result = await SentryTokenCheck().run(context(
          cfg: sentryConfig, env: {'SENTRY_ORG_TOKEN': 'sntryu_abc'}));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('legacy SENTRY_ORG_TOKEN'));
    });
  });

  group('AmplitudeKeyCheck', () {
    final amplitudeConfig = config('''
app: { name: X, bundle_id: com.x }
amplitude:
''');

    test('skips when amplitude is not configured', () async {
      final result = await AmplitudeKeyCheck()
          .run(context(cfg: config('app: { name: X, bundle_id: com.x }')));
      expect(result.status, CheckStatus.skipped);
    });

    test('errors when the key is missing, naming the console step', () async {
      final result = await AmplitudeKeyCheck().run(context(cfg: amplitudeConfig));
      expect(result.status, CheckStatus.error);
      expect(result.fix, contains('Organization settings'));
      expect(result.detail, contains('AMPLITUDE_API_KEY'));
    });

    test('warns while only the production key is exported', () async {
      final result = await AmplitudeKeyCheck().run(context(
          cfg: amplitudeConfig, env: {'AMPLITUDE_API_KEY': 'prod'}));
      expect(result.status, CheckStatus.warning);
      expect(result.detail, contains('AMPLITUDE_DEV_API_KEY missing'));
    });

    test('ok with both keys', () async {
      final result = await AmplitudeKeyCheck().run(context(
        cfg: amplitudeConfig,
        env: {
          'AMPLITUDE_API_KEY': 'prod',
          'AMPLITUDE_DEV_API_KEY': 'dev',
        },
      ));
      expect(result.status, CheckStatus.ok);
    });

    test('a custom api_key_env is the one reported', () async {
      final result = await AmplitudeKeyCheck().run(context(
          cfg: config('''
app: { name: X, bundle_id: com.x }
amplitude: { api_key_env: DIARY_KEY }
''')));
      expect(result.detail, contains('DIARY_KEY'));
    });
  });

  group('AdmobApiAccessCheck', () {
    final admobConfig = config('app: { name: X, bundle_id: com.x }\nadmob: {}');

    test('warns when no credential is available', () async {
      final result = await AdmobApiAccessCheck().run(context(cfg: admobConfig));
      expect(result.status, CheckStatus.warning);
      expect(result.fix, contains('gcloud auth application-default login'));
    });

    test('names an access token', () async {
      final result = await AdmobApiAccessCheck().run(context(
          cfg: admobConfig, env: {'ADMOB_ACCESS_TOKEN': 'ya29.token'}));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, 'ADMOB_ACCESS_TOKEN');
    });

    test('names a refresh-token client', () async {
      final result = await AdmobApiAccessCheck().run(context(
        cfg: admobConfig,
        env: {
          'ADMOB_REFRESH_TOKEN': 'refresh',
          'ADMOB_OAUTH_CLIENT_ID': 'id',
          'ADMOB_OAUTH_CLIENT_SECRET': 'secret',
        },
      ));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('OAuth client'));
    });

    test('falls back to gcloud when it is installed', () async {
      final result = await AdmobApiAccessCheck()
          .run(context(cfg: admobConfig, installed: {'gcloud': 'gcloud 500'}));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('gcloud'));
    });

    test('an installed gcloud without a login is not a credential', () async {
      final result = await AdmobApiAccessCheck().run(context(
        cfg: admobConfig,
        installed: {'gcloud': 'gcloud 500'},
        gcloudLoggedIn: false,
      ));
      expect(result.status, CheckStatus.warning);
    });

    test('skips when every ID is already declared', () async {
      final result = await AdmobApiAccessCheck().run(context(
          cfg: config('''
app: { name: X, bundle_id: com.x }
admob:
  ios_app_id: ca-app-pub-1234567890123456~1234567890
  android_app_id: ca-app-pub-1234567890123456~0987654321
  ad_units:
    banner_main:
      ios: ca-app-pub-1234567890123456/1111111111
      android: ca-app-pub-1234567890123456/2222222222
''')));
      expect(result.status, CheckStatus.skipped);
    });

    test('skips when admob.auto is off', () async {
      final result = await AdmobApiAccessCheck().run(context(
          cfg: config(
              'app: { name: X, bundle_id: com.x }\nadmob: { auto: false }')));
      expect(result.status, CheckStatus.skipped);
    });
  });

  group('AdmobAppIdCheck', () {
    test('warns when app IDs are missing and nothing can look them up',
        () async {
      final result = await AdmobAppIdCheck().run(context(
          cfg: config('app: { name: X, bundle_id: com.x }\nadmob: {}')));
      expect(result.status, CheckStatus.warning);
      expect(result.fix, contains('AdMob console'));
    });

    test('missing app IDs are fine when the API can resolve them', () async {
      final result = await AdmobAppIdCheck().run(context(
        cfg: config('app: { name: X, bundle_id: com.x }\nadmob: {}'),
        env: {'ADMOB_ACCESS_TOKEN': 'ya29.token'},
      ));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('looked up through the AdMob API'));
    });

    test('a malformed ID is reported even when the other is missing',
        () async {
      final result = await AdmobAppIdCheck().run(context(
        cfg: config('app: { name: X, bundle_id: com.x }\n'
            'admob: { ios_app_id: bogus }'),
        env: {'ADMOB_ACCESS_TOKEN': 'ya29.token'},
      ));
      expect(result.status, CheckStatus.warning);
      expect(result.detail, contains('ios_app_id'));
    });

    test('auto: false keeps missing app IDs a warning', () async {
      final result = await AdmobAppIdCheck().run(context(
        cfg: config(
            'app: { name: X, bundle_id: com.x }\nadmob: { auto: false }'),
        env: {'ADMOB_ACCESS_TOKEN': 'ya29.token'},
      ));
      expect(result.status, CheckStatus.warning);
    });

    test('warns on malformed app IDs', () async {
      final result = await AdmobAppIdCheck().run(context(
          cfg: config('''
app: { name: X, bundle_id: com.x }
admob: { ios_app_id: bogus, android_app_id: bogus }
''')));
      expect(result.status, CheckStatus.warning);
    });

    test('ok on well-formed app IDs', () async {
      final result = await AdmobAppIdCheck().run(context(
          cfg: config('''
app: { name: X, bundle_id: com.x }
admob:
  ios_app_id: ca-app-pub-1234567890123456~1234567890
  android_app_id: ca-app-pub-1234567890123456~0987654321
''')));
      expect(result.status, CheckStatus.ok);
    });
  });

  group('DartDefineFileCheck', () {
    late Directory tempDir;

    setUp(() => tempDir = Directory.systemTemp.createTempSync('define_check'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    DoctorContext ctx(ProjectConfig cfg) =>
        context(projectRoot: tempDir.path, cfg: cfg);

    final withSentry = config('''
app: { name: X, bundle_id: com.x }
sentry: { org: my-org }
''');

    test('skips when no step writes dart-defines', () async {
      final result = await DartDefineFileCheck()
          .run(ctx(config('app: { name: X, bundle_id: com.x }')));
      expect(result.status, CheckStatus.skipped);
    });

    test('warns when the file a release build needs is missing', () async {
      final result = await DartDefineFileCheck().run(ctx(withSentry));
      expect(result.status, CheckStatus.warning);
      expect(result.detail, contains('env.prod.json'));
      expect(result.fix, contains('compiles as an empty string'));
    });

    test('ok with a key count, never the values', () async {
      File(p.join(tempDir.path, 'env.prod.json')).writeAsStringSync(
          '{"SENTRY_DSN": "https://key@o1.ingest/1", "APP_ENV": "prod"}');
      final result = await DartDefineFileCheck().run(ctx(withSentry));
      expect(result.status, CheckStatus.ok);
      expect(result.detail, 'env.prod.json, 2 key(s)');
      expect(result.detail, isNot(contains('key@')));
    });

    test('an empty value is called out — the SDK would no-op', () async {
      File(p.join(tempDir.path, 'env.prod.json'))
          .writeAsStringSync('{"SENTRY_DSN": ""}');
      final result = await DartDefineFileCheck().run(ctx(withSentry));
      expect(result.status, CheckStatus.warning);
      expect(result.detail, contains('empty: SENTRY_DSN'));
    });

    test('invalid JSON is an error', () async {
      File(p.join(tempDir.path, 'env.prod.json')).writeAsStringSync('nope');
      final result = await DartDefineFileCheck().run(ctx(withSentry));
      expect(result.status, CheckStatus.error);
    });
  });

  group('DoctorRunner / DoctorReport', () {
    test('runs the default checks and renders grouped output', () async {
      final ctx = context(
        cfg: iosConfig,
        installed: {
          'flutter': 'Flutter 3.35.0',
          'dart': 'Dart SDK version: 3.10.8',
          'git': 'git version 2.47.0',
          'xcodebuild': 'Xcode 16.2',
          'pod': '1.16.2',
          'fastlane': 'fastlane 2.226.0',
        },
      );
      final report = await DoctorRunner(ctx).run();
      final rendered = report.render();

      expect(rendered, contains('Environment'));
      expect(rendered, contains('Project'));
      expect(rendered, contains('iOS deploy'));
      expect(rendered, contains('Summary:'));
      // ASC key env vars are absent → at least one error.
      expect(report.hasErrors, isTrue);
      expect(report.okCount, greaterThanOrEqualTo(6));
    });

    test('skips Firebase CLI checks when firebase is not configured', () {
      final checks = DoctorRunner.defaultChecks(context(cfg: iosConfig));
      final titles = checks.whereType<ToolCheck>().map((c) => c.title);
      expect(titles, isNot(contains('Firebase CLI')));
    });

    test('includes Firebase CLI checks when firebase is configured', () {
      final firebaseConfig = config('''
app: { name: X, bundle_id: com.x }
firebase: { analytics: true }
''');
      final checks = DoctorRunner.defaultChecks(context(cfg: firebaseConfig));
      final titles = checks.whereType<ToolCheck>().map((c) => c.title);
      expect(titles, contains('Firebase CLI'));
      expect(titles, contains('FlutterFire CLI'));
    });

    test('counts statuses per kind', () async {
      final report = DoctorReport([
        ('Environment', const CheckResult.ok('A')),
        ('Environment', const CheckResult.warning('B')),
        ('Project', const CheckResult.error('C')),
        ('Integrations', const CheckResult.skipped('D')),
      ]);
      expect(report.okCount, 1);
      expect(report.warningCount, 1);
      expect(report.errorCount, 1);
      expect(report.skippedCount, 1);
      expect(report.hasErrors, isTrue);
      expect(report.render(), contains('1 ok · 1 warning(s) · 1 error(s)'));
    });
  });
}
