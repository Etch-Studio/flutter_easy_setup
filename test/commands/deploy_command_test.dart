import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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

    test('android platform points at milestone M3', () async {
      writeConfig('app: { name: X, bundle_id: com.x }\n');
      expect(
        () => DeployCommand.run(
            projectRoot: tempDir.path, platform: 'android', dryRun: true),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('M3'))),
      );
    });

    test('android section without --platform fails fast with guidance',
        () async {
      writeConfig('''
app: { name: X, bundle_id: com.x }
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
android: {}
''');
      expect(
        () => DeployCommand.run(projectRoot: tempDir.path, dryRun: true),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('--platform ios'))),
      );
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
