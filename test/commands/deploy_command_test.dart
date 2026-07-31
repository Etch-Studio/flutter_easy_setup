import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Fake with all tools installed that records streamed commands.
class _FakeProcessRunner extends ProcessRunner {
  final streamed = <(String, List<String>)>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      executable == 'git' && arguments.first == 'describe'
          ? ProcessResult(0, 128, '', 'fatal: no tag')
          : ProcessResult(0, 0, '', '');

  @override
  Future<String?> which(String command) async => '/usr/bin/$command';

  @override
  Future<String?> versionOf(
    String command, {
    List<String> arguments = const ['--version'],
    Pattern? linePattern,
  }) async =>
      '$command 1.0.0';

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

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('deploy_command_test');
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync(
        'name: app\nversion: 1.0.0+1\ndependencies:\n  flutter:\n    sdk: flutter\n');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  void writeConfig(String yaml) =>
      File(p.join(tempDir.path, 'easy_setup.yaml')).writeAsStringSync(yaml);

  group('DeployCommand', () {
    test('errors when no deployable section is configured', () async {
      writeConfig('app: { name: X, bundle_id: com.x }\n');
      expect(
        () => DeployCommand.run(projectRoot: tempDir.path, dryRun: true),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('Nothing to deploy'))),
      );
    });

    test("explicit android platform without the section explains itself",
        () async {
      writeConfig('app: { name: X, bundle_id: com.x }\n');
      expect(
        () => DeployCommand.run(
            projectRoot: tempDir.path, platform: 'android', dryRun: true),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains("'android' section"))),
      );
    });

    test('deploys both configured platforms in one run (dry-run)', () async {
      writeConfig('''
app: { name: X, bundle_id: com.x }
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
android: {}
''');
      final out = StringBuffer();
      final exitCode = await DeployCommand.run(
        projectRoot: tempDir.path,
        dryRun: true,
        out: out,
      );
      expect(exitCode, 0);
      expect(out.toString(), contains('===== ios ====='));
      expect(out.toString(), contains('===== android ====='));
      expect(out.toString(), contains('fastlane match'));
      expect(out.toString(), contains('fastlane supply'));
    });

    test('--if-configured skips a missing platform with exit 0', () async {
      writeConfig('''
app: { name: X, bundle_id: com.x }
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
''');
      final out = StringBuffer();
      final exitCode = await DeployCommand.run(
        projectRoot: tempDir.path,
        platform: 'android',
        ifConfigured: true,
        out: out,
      );
      expect(exitCode, 0);
      expect(out.toString(), contains('Skipping android'));
    });

    test('verifies every platform before any upload starts', () async {
      writeConfig('''
app: { name: X, bundle_id: com.x }
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
android: {}
''');
      final processes = _FakeProcessRunner();
      // iOS secrets complete, Android service account missing — the failure
      // must surface before the iOS pipeline runs a single command.
      await expectLater(
        () => DeployCommand.run(
          projectRoot: tempDir.path,
          env: const {
            'ASC_KEY_ID': 'KEY123',
            'ASC_ISSUER_ID': 'issuer-uuid',
            'ASC_KEY_P8': '-----BEGIN PRIVATE KEY-----',
            'MATCH_PASSWORD': 'secret',
          },
          processes: processes,
          out: StringBuffer(),
        ),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('preflight failed'))),
      );
      expect(processes.streamed, isEmpty);
    });

    test('dry-run deploys ios end-to-end', () async {
      writeConfig('''
app: { name: X, bundle_id: com.x }
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
''');
      final out = StringBuffer();
      final exitCode = await DeployCommand.run(
        projectRoot: tempDir.path,
        dryRun: true,
        out: out,
      );
      expect(exitCode, 0);
      expect(out.toString(), contains('fastlane match'));
      expect(out.toString(), contains('pilot upload'));
    });
  });
}
