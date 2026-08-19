import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Records streamed invocations and snapshots the ephemeral files fastlane /
/// flutter would read (api_key.json, ExportOptions.plist) at call time —
/// they are deleted before the deploy returns.
class DeployFakeProcessRunner extends ProcessRunner {
  final Map<String, String> installed;
  final List<(String, List<String>)> streamed = [];
  String? apiKeyJsonAtMatch;
  String? exportOptionsAtBuild;
  int exitCodeFor(String executable, List<String> arguments) => 0;

  DeployFakeProcessRunner({this.installed = const {}});

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (executable == 'git' && arguments.first == 'describe') {
      return ProcessResult(0, 128, '', 'fatal: no tag exactly matches');
    }
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<String?> which(String command) async =>
      installed.containsKey(command) ? '/usr/bin/$command' : null;

  @override
  Future<String?> versionOf(
    String command, {
    List<String> arguments = const ['--version'],
    Pattern? linePattern,
  }) async =>
      installed[command];

  @override
  Future<int> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    streamed.add((executable, arguments));
    if (executable == 'fastlane' && arguments.first == 'match') {
      final keyPath = arguments[arguments.indexOf('--api_key_path') + 1];
      apiKeyJsonAtMatch = File(keyPath).readAsStringSync();
    }
    if (executable == 'flutter') {
      final optionsArg = arguments
          .firstWhere((arg) => arg.startsWith('--export-options-plist='));
      exportOptionsAtBuild =
          File(optionsArg.split('=').last).readAsStringSync();
      // Simulate the build producing an .ipa (the deployer wipes the output
      // directory right before this step).
      final ipaDir =
          Directory(p.join(workingDirectory!, 'build', 'ios', 'ipa'))
            ..createSync(recursive: true);
      File(p.join(ipaDir.path, 'app.ipa')).writeAsStringSync('fresh-ipa');
    }
    return exitCodeFor(executable, arguments);
  }
}

const _fullEnv = {
  'ASC_KEY_ID': 'KEY123',
  'ASC_ISSUER_ID': 'issuer-uuid',
  'ASC_KEY_P8': '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
  'MATCH_PASSWORD': 'secret',
};

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ios_deployer_test');
    File(p.join(tempDir.path, 'pubspec.yaml'))
        .writeAsStringSync('name: app\nversion: 1.2.0+8\n');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config([String extra = '']) => ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
$extra
''') as Map);

  IosDeployer deployer({
    ProjectConfig? cfg,
    Map<String, String> env = _fullEnv,
    DeployFakeProcessRunner? processes,
    bool dryRun = false,
  }) =>
      IosDeployer(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: env,
        processes: processes ?? DeployFakeProcessRunner(),
        dryRun: dryRun,
        out: out,
        isMacOS: true,
      );

  group('IosDeployer', () {
    test('requires ios.team_id and ios.match_git_url', () async {
      final cfg = ProjectConfig.fromYaml(
          loadYaml('app: { name: X, bundle_id: com.x }\nios: {}') as Map);
      expect(
        () => deployer(cfg: cfg, dryRun: true).run(),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('ios.team_id'))),
      );
    });

    test('dry-run previews all steps without executing anything', () async {
      final processes = DeployFakeProcessRunner();
      final exitCode = await deployer(
        processes: processes,
        env: const {},
        dryRun: true,
      ).run();
      expect(exitCode, 0);
      expect(processes.streamed, isEmpty);
      final output = out.toString();
      expect(output, contains('fastlane match'));
      expect(output, contains('flutter build ipa'));
      expect(output, contains('pilot upload'));
      expect(output, contains('1.2.0+8'));
      expect(output, contains('[dry-run]'));
    });

    test('the release build carries env.prod.json as dart-defines', () async {
      File(p.join(tempDir.path, 'env.prod.json'))
          .writeAsStringSync('{"SENTRY_DSN": "https://k@o1.ingest/1"}');
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      await deployer(
        processes: processes,
        cfg: config('sentry: { org: my-org }'),
      ).run();
      final build =
          processes.streamed.firstWhere((call) => call.$2.contains('ipa')).$2;
      expect(build, contains('--dart-define-from-file=env.prod.json'));
    });

    test('a project without the env file is warned about, not blocked',
        () async {
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      await deployer(
        processes: processes,
        cfg: config('sentry: { org: my-org }'),
      ).run();
      final build =
          processes.streamed.firstWhere((call) => call.$2.contains('ipa')).$2;
      expect(build.where((arg) => arg.startsWith('--dart-define')), isEmpty);
      expect(out.toString(), contains('compile as empty strings'));
    });

    test('preflight aborts with doctor findings when secrets are missing',
        () async {
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      await expectLater(
        () => deployer(processes: processes, env: const {}).run(),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('preflight failed'))),
      );
      expect(processes.streamed, isEmpty);
    });

    test('runs match → signing → build ipa → pilot with ephemeral files',
        () async {
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});

      final exitCode = await deployer(processes: processes).run(
        buildNumberOverride: '77',
      );
      expect(exitCode, 0);

      expect(processes.streamed.map((call) => call.$1).toList(),
          ['fastlane', 'fastlane', 'flutter', 'fastlane']);
      final match = processes.streamed[0].$2;
      expect(match.take(2), ['match', 'appstore']);
      expect(match, containsAllInOrder(['--app_identifier', 'com.x']));
      expect(match,
          containsAllInOrder(['--git_url', 'git@github.com:org/certs.git']));
      // Local run (no CI env) → write mode.
      expect(match, containsAllInOrder(['--readonly', 'false']));

      final signing = processes.streamed[1].$2;
      expect(signing.take(2), ['run', 'update_code_signing_settings']);
      expect(signing, contains('use_automatic_signing:false'));
      expect(signing, contains('profile_name:match AppStore com.x'));

      final build = processes.streamed[2].$2;
      expect(build, contains('--build-name=1.2.0'));
      expect(build, contains('--build-number=77'));

      final pilot = processes.streamed[3].$2;
      expect(pilot.take(2), ['pilot', 'upload']);
      expect(pilot, containsAllInOrder(
          ['--ipa', p.join(tempDir.path, 'build', 'ios', 'ipa', 'app.ipa')]));

      // The API key JSON existed at match time and carried the raw p8.
      final apiKey = json.decode(processes.apiKeyJsonAtMatch!) as Map;
      expect(apiKey['key_id'], 'KEY123');
      expect(apiKey['key'], contains('BEGIN PRIVATE KEY'));

      // ExportOptions.plist pointed at the match App Store profile.
      expect(processes.exportOptionsAtBuild, contains('app-store'));
      expect(processes.exportOptionsAtBuild,
          contains('match AppStore com.x'));
      expect(processes.exportOptionsAtBuild, contains('ABCDE12345'));
    });

    test('match runs read-only in CI, and stale ipas are wiped pre-build',
        () async {
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      final ipaDir = Directory(p.join(tempDir.path, 'build', 'ios', 'ipa'))
        ..createSync(recursive: true);
      final stale = File(p.join(ipaDir.path, 'stale.ipa'))
        ..writeAsStringSync('old');

      await deployer(
        processes: processes,
        env: {..._fullEnv, 'CI': 'true'},
      ).run();

      final match = processes.streamed[0].$2;
      expect(match, containsAllInOrder(['--readonly', 'true']));

      // The stale artifact was removed; pilot got the freshly built ipa.
      expect(stale.existsSync(), isFalse);
      final pilot = processes.streamed[3].$2;
      expect(pilot, containsAllInOrder(
          ['--ipa', p.join(ipaDir.path, 'app.ipa')]));
    });

    test('explicit matchReadonly overrides the CI auto-detection', () async {
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      final withOverride = IosDeployer(
        projectRoot: tempDir.path,
        config: config(),
        env: _fullEnv,
        processes: processes,
        matchReadonly: true,
        out: out,
        isMacOS: true,
      );
      await withOverride.run();
      expect(processes.streamed[0].$2,
          containsAllInOrder(['--readonly', 'true']));
    });

    test('rejects a pre-release version before running anything', () async {
      File(p.join(tempDir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: app\nversion: 1.2.0-beta+8\n');
      final processes = DeployFakeProcessRunner();
      expect(
        () => deployer(processes: processes, dryRun: true).run(),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            contains('CFBundleShortVersionString'))),
      );
      expect(processes.streamed, isEmpty);
    });

    test('reads the p8 from ASC_KEY_P8_PATH when raw content is absent',
        () async {
      final p8File = File(p.join(tempDir.path, 'AuthKey.p8'))
        ..writeAsStringSync('p8-from-file');
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      final ipaDir = Directory(p.join(tempDir.path, 'build', 'ios', 'ipa'))
        ..createSync(recursive: true);
      File(p.join(ipaDir.path, 'app.ipa')).writeAsStringSync('ipa');

      await deployer(processes: processes, env: {
        'ASC_KEY_ID': 'KEY123',
        'ASC_ISSUER_ID': 'issuer-uuid',
        'ASC_KEY_P8_PATH': p8File.path,
        'MATCH_PASSWORD': 'secret',
      }).run();

      final apiKey = json.decode(processes.apiKeyJsonAtMatch!) as Map;
      expect(apiKey['key'], 'p8-from-file');
    });

    test('--submit runs deliver submit_for_review after pilot', () async {
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      final submitting = IosDeployer(
        projectRoot: tempDir.path,
        config: config(),
        env: _fullEnv,
        processes: processes,
        submit: true,
        out: out,
        isMacOS: true,
      );
      await submitting.run(buildNumberOverride: '9');

      final deliver = processes.streamed.last.$2;
      expect(deliver.first, 'deliver');
      expect(deliver, containsAllInOrder(['--submit_for_review', 'true']));
      expect(deliver, containsAllInOrder(['--skip_metadata', 'true']));
      expect(deliver, containsAllInOrder(['--app_version', '1.2.0']));
      expect(deliver, containsAllInOrder(['--build_number', '9']));

      // Submission needs a processed build — pilot must wait.
      final pilot =
          processes.streamed.firstWhere((c) => c.$2.first == 'pilot').$2;
      expect(pilot, containsAllInOrder(
          ['--skip_waiting_for_build_processing', 'false']));
    });

    test('without --submit no deliver call happens', () async {
      final processes = DeployFakeProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      await deployer(processes: processes).run();
      expect(processes.streamed.where((c) => c.$2.first == 'deliver'),
          isEmpty);
    });

    test('fails with the step name when a tool exits non-zero', () async {
      final processes = _FailingBuildProcessRunner(
          installed: {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'});
      expect(
        () => deployer(processes: processes).run(),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('flutter build ipa'))),
      );
    });
  });
}

class _FailingBuildProcessRunner extends DeployFakeProcessRunner {
  _FailingBuildProcessRunner({super.installed});

  @override
  int exitCodeFor(String executable, List<String> arguments) =>
      executable == 'flutter' ? 65 : 0;
}
