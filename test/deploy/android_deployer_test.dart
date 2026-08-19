import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Records streamed invocations; simulates `flutter build appbundle`
/// producing the .aab and snapshots the ephemeral json key at supply time.
class AndroidFakeProcessRunner extends ProcessRunner {
  final Map<String, String> installed;
  final List<(String, List<String>)> streamed = [];
  String? jsonKeyAtSupply;

  AndroidFakeProcessRunner({this.installed = const {}});

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
    if (executable == 'flutter') {
      final aab = File(p.join(workingDirectory!, 'build', 'app', 'outputs',
          'bundle', 'release', 'app-release.aab'));
      aab.createSync(recursive: true);
    }
    if (executable == 'fastlane' && arguments.first == 'supply') {
      final keyPath = arguments[arguments.indexOf('--json_key') + 1];
      jsonKeyAtSupply = File(keyPath).readAsStringSync();
    }
    return 0;
  }
}

const _tools = {'flutter': 'Flutter 3.44.0', 'fastlane': 'fastlane 2'};
const _serviceAccountJson =
    '{"client_email": "ci@project.iam.gserviceaccount.com"}';

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('android_deployer_test');
    File(p.join(tempDir.path, 'pubspec.yaml'))
        .writeAsStringSync('name: app\nversion: 2.4.0+13\n');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config([String androidSection = 'android: {}']) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x, package_name: com.x.android }
$androidSection
''') as Map);

  AndroidDeployer deployer({
    ProjectConfig? cfg,
    Map<String, String> env = const {
      'PLAY_SERVICE_ACCOUNT_JSON': _serviceAccountJson,
    },
    AndroidFakeProcessRunner? processes,
    bool dryRun = false,
    String? track,
  }) =>
      AndroidDeployer(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: env,
        processes: processes ?? AndroidFakeProcessRunner(),
        dryRun: dryRun,
        track: track,
        out: out,
        isMacOS: true,
      );

  group('AndroidDeployer', () {
    test("requires the 'android' section", () async {
      final cfg = ProjectConfig.fromYaml(
          loadYaml('app: { name: X, bundle_id: com.x }') as Map);
      expect(
        () => deployer(cfg: cfg, dryRun: true).run(),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains("'android' section"))),
      );
    });

    test('rejects an unknown track override', () async {
      expect(
        () => deployer(dryRun: true, track: 'nightly').run(),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('nightly'))),
      );
    });

    test('dry-run previews build + supply without executing anything',
        () async {
      final processes = AndroidFakeProcessRunner();
      final exitCode =
          await deployer(processes: processes, env: const {}, dryRun: true)
              .run();
      expect(exitCode, 0);
      expect(processes.streamed, isEmpty);
      final output = out.toString();
      expect(output, contains('flutter build appbundle'));
      expect(output, contains('fastlane supply'));
      expect(output, contains('track "internal"'));
      expect(output, contains('2.4.0+13'));
    });

    test('preflight aborts when the service account is missing', () async {
      final processes = AndroidFakeProcessRunner(installed: _tools);
      await expectLater(
        () => deployer(processes: processes, env: const {}).run(),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('preflight failed'))),
      );
      expect(processes.streamed, isEmpty);
    });

    test('the release build carries env.prod.json as dart-defines', () async {
      File(p.join(tempDir.path, 'env.prod.json'))
          .writeAsStringSync('{"ADMOB_BANNER_MAIN_ANDROID": "ca-app-pub-1/1"}');
      final processes = AndroidFakeProcessRunner(installed: _tools);
      await deployer(
        processes: processes,
        cfg: config('android: {}\nadmob: { auto: false }'),
      ).run(buildNumberOverride: '55');
      expect(processes.streamed[0].$2,
          contains('--dart-define-from-file=env.prod.json'));
    });

    test('runs build appbundle → supply with an ephemeral json key',
        () async {
      final processes = AndroidFakeProcessRunner(installed: _tools);
      final exitCode = await deployer(processes: processes)
          .run(buildNumberOverride: '55');
      expect(exitCode, 0);

      expect(processes.streamed.map((call) => call.$1).toList(),
          ['flutter', 'fastlane']);
      final build = processes.streamed[0].$2;
      expect(build.take(2), ['build', 'appbundle']);
      expect(build, contains('--build-name=2.4.0'));
      expect(build, contains('--build-number=55'));

      final supply = processes.streamed[1].$2;
      expect(supply.first, 'supply');
      expect(supply,
          containsAllInOrder(['--package_name', 'com.x.android']));
      expect(supply, containsAllInOrder(['--track', 'internal']));
      expect(supply, containsAllInOrder(['--skip_upload_metadata', 'true']));

      // Raw JSON was materialized as an ephemeral file for --json_key.
      expect(processes.jsonKeyAtSupply, _serviceAccountJson);
    });

    test('supply uploads store assets when the M5 pipeline produced them',
        () async {
      Directory(p.join(tempDir.path, 'fastlane', 'metadata', 'android', 'ko',
              'images', 'phoneScreenshots'))
          .createSync(recursive: true);
      final processes = AndroidFakeProcessRunner(installed: _tools);
      await deployer(processes: processes).run();
      final supply = processes.streamed[1].$2;
      expect(supply, containsAllInOrder(['--skip_upload_images', 'false']));
      expect(supply,
          containsAllInOrder(['--skip_upload_screenshots', 'false']));
      // Listing texts are never generated by easy_setup.
      expect(supply, containsAllInOrder(['--skip_upload_metadata', 'true']));
    });

    test('supply skips store assets when none were generated', () async {
      final processes = AndroidFakeProcessRunner(installed: _tools);
      await deployer(processes: processes).run();
      final supply = processes.streamed[1].$2;
      expect(supply, containsAllInOrder(['--skip_upload_images', 'true']));
    });

    test('track comes from android.play_track_default, override wins',
        () async {
      final processes = AndroidFakeProcessRunner(installed: _tools);
      await deployer(
        cfg: config('android: { play_track_default: beta }'),
        processes: processes,
      ).run();
      expect(processes.streamed[1].$2,
          containsAllInOrder(['--track', 'beta']));

      final overrideProcesses = AndroidFakeProcessRunner(installed: _tools);
      await deployer(processes: overrideProcesses, track: 'production').run();
      expect(overrideProcesses.streamed[1].$2,
          containsAllInOrder(['--track', 'production']));
    });

    test('a path-valued PLAY_SERVICE_ACCOUNT_JSON is passed through',
        () async {
      final keyFile = File(p.join(tempDir.path, 'sa.json'))
        ..writeAsStringSync(_serviceAccountJson);
      final processes = AndroidFakeProcessRunner(installed: _tools);
      await deployer(
        processes: processes,
        env: {'PLAY_SERVICE_ACCOUNT_JSON': keyFile.path},
      ).run();
      expect(processes.streamed[1].$2,
          containsAllInOrder(['--json_key', keyFile.path]));
    });

    test('fails when the build produces no .aab', () async {
      final processes = _NoAabProcessRunner(installed: _tools);
      expect(
        () => deployer(processes: processes).run(),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('No app bundle found'))),
      );
    });
  });
}

class _NoAabProcessRunner extends AndroidFakeProcessRunner {
  _NoAabProcessRunner({super.installed});

  @override
  Future<int> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    streamed.add((executable, arguments));
    return 0;
  }
}
