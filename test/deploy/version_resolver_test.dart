import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Fake that only answers `git describe --tags --exact-match`.
class GitFakeProcessRunner extends ProcessRunner {
  final int exitCode;
  final String tag;
  const GitFakeProcessRunner({this.exitCode = 0, this.tag = ''});

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      ProcessResult(0, exitCode, '$tag\n', '');
}

/// Simulates a machine without git on PATH.
class _ThrowingProcessRunner extends ProcessRunner {
  const _ThrowingProcessRunner();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      throw ProcessException(executable, arguments, 'not found', 127);
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('version_resolver_test');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  void writePubspec(String version) =>
      File(p.join(tempDir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: app\nversion: $version\n');

  group('VersionResolver', () {
    test('a v* tag at HEAD wins over pubspec', () async {
      writePubspec('0.9.0+7');
      final version = await VersionResolver.resolve(
        projectRoot: tempDir.path,
        processes: const GitFakeProcessRunner(tag: 'v1.2.3'),
      );
      expect(version.buildName, '1.2.3');
      expect(version.source, contains('git tag'));
      // Build number still comes from the pubspec +N suffix.
      expect(version.buildNumber, '7');
    });

    test('falls back to pubspec when HEAD has no tag', () async {
      writePubspec('2.0.1+3');
      final version = await VersionResolver.resolve(
        projectRoot: tempDir.path,
        processes: const GitFakeProcessRunner(exitCode: 128),
      );
      expect(version.buildName, '2.0.1');
      expect(version.buildNumber, '3');
      expect(version.source, 'pubspec.yaml');
    });

    test('ignores non-v tags', () async {
      writePubspec('1.0.0');
      final version = await VersionResolver.resolve(
        projectRoot: tempDir.path,
        processes: const GitFakeProcessRunner(tag: 'release-2024'),
      );
      expect(version.source, 'pubspec.yaml');
    });

    test('build number precedence: override > CI run number > pubspec',
        () async {
      writePubspec('1.0.0+5');
      final overridden = await VersionResolver.resolve(
        projectRoot: tempDir.path,
        env: {'GITHUB_RUN_NUMBER': '99'},
        buildNumberOverride: '42',
        processes: const GitFakeProcessRunner(exitCode: 128),
      );
      expect(overridden.buildNumber, '42');

      final fromCi = await VersionResolver.resolve(
        projectRoot: tempDir.path,
        env: {'GITHUB_RUN_NUMBER': '99'},
        processes: const GitFakeProcessRunner(exitCode: 128),
      );
      expect(fromCi.buildNumber, '99');
    });

    test('build number defaults to 1 without any source', () async {
      writePubspec('1.0.0');
      final version = await VersionResolver.resolve(
        projectRoot: tempDir.path,
        processes: const GitFakeProcessRunner(exitCode: 128),
      );
      expect(version.buildNumber, '1');
    });

    test('missing git falls back to pubspec', () async {
      writePubspec('3.1.0+2');
      final version = await VersionResolver.resolve(
        projectRoot: tempDir.path,
        processes: const _ThrowingProcessRunner(),
      );
      expect(version.buildName, '3.1.0');
      expect(version.source, 'pubspec.yaml');
    });

    test('throws when neither tag nor pubspec version exists', () async {
      File(p.join(tempDir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: app\n');
      expect(
        () => VersionResolver.resolve(
          projectRoot: tempDir.path,
          processes: const GitFakeProcessRunner(exitCode: 128),
        ),
        throwsA(isA<SetupException>()),
      );
    });
  });
}
