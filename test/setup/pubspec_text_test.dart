import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Records what would have been added, and can pretend flutter is missing or
/// that `pub add` failed.
class _PubProcessRunner extends ProcessRunner {
  final bool flutterInstalled;
  final int addExitCode;
  final streamed = <(String, List<String>)>[];

  _PubProcessRunner({this.flutterInstalled = true, this.addExitCode = 0});

  @override
  Future<String?> which(String command) async =>
      flutterInstalled ? '/usr/bin/$command' : null;

  @override
  Future<int> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    streamed.add((executable, arguments));
    return addExitCode;
  }
}

const _pubspec = '''
name: my_app
description: An app.

environment:
  sdk: ^3.5.0

dependencies:
  flutter:
    sdk: flutter
  path: ^1.9.0

dev_dependencies:
  flutter_test:
    sdk: flutter

flutter:
  uses-material-design: true
''';

void main() {
  group('PubspecText.hasDependency', () {
    test('finds dependencies and dev dependencies', () {
      expect(PubspecText.hasDependency(_pubspec, 'path'), isTrue);
      expect(PubspecText.hasDependency(_pubspec, 'flutter_test'), isTrue);
      expect(PubspecText.hasDependency(_pubspec, 'sentry_flutter'), isFalse);
    });

    test('a broken pubspec is reported, not silently ignored', () {
      expect(
        () => PubspecText.hasDependency('name: app\n  bad: [', 'path'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('pubspec.yaml'))),
      );
    });
  });

  group('PubspecText.ensureTopLevelBlock', () {
    test('appends the block when the file has none', () {
      final updated = PubspecText.ensureTopLevelBlock(_pubspec, 'sentry', {
        'upload_debug_symbols': true,
        'org': 'my-org',
        'project': 'my-app',
      });
      expect(updated, endsWith('sentry:\n'
          '  upload_debug_symbols: true\n'
          '  org: my-org\n'
          '  project: my-app\n'));
      // Everything that was there is still there.
      expect(updated, contains('uses-material-design: true'));
      expect(loadYaml(updated) as Map, containsPair('name', 'my_app'));
    });

    test('updates the keys it owns and leaves the others alone', () {
      final existing = '$_pubspec'
          '\nsentry:\n'
          '  # keep this comment\n'
          '  upload_source_maps: true\n'
          '  org: old-org\n'
          '  project: old-project\n';
      final updated = PubspecText.ensureTopLevelBlock(existing, 'sentry', {
        'upload_debug_symbols': true,
        'org': 'new-org',
        'project': 'new-project',
      });
      final block = loadYaml(updated)['sentry'] as Map;
      expect(block['org'], 'new-org');
      expect(block['project'], 'new-project');
      expect(block['upload_debug_symbols'], true);
      // A developer's own key survives.
      expect(block['upload_source_maps'], true);
      expect(updated, contains('# keep this comment'));
    });

    test('follows the indentation the block already uses', () {
      final existing = '$_pubspec\nsentry:\n    org: old-org\n';
      final updated = PubspecText.ensureTopLevelBlock(existing, 'sentry', {
        'org': 'new-org',
        'project': 'my-app',
      });
      expect(updated, contains('    org: new-org\n'));
      expect(updated, contains('    project: my-app\n'));
    });

    test('a following top-level section is not swallowed', () {
      final existing = 'name: my_app\n'
          'sentry:\n'
          '  org: my-org\n'
          '\n'
          'flutter:\n'
          '  uses-material-design: true\n';
      final updated = PubspecText.ensureTopLevelBlock(existing, 'sentry', {
        'project': 'my-app',
      });
      expect(updated, 'name: my_app\n'
          'sentry:\n'
          '  org: my-org\n'
          '  project: my-app\n'
          '\n'
          'flutter:\n'
          '  uses-material-design: true\n');
    });

    test('is idempotent — a second pass changes nothing', () {
      final once = PubspecText.ensureTopLevelBlock(
          _pubspec, 'sentry', {'org': 'my-org', 'project': 'my-app'});
      final twice = PubspecText.ensureTopLevelBlock(
          once, 'sentry', {'org': 'my-org', 'project': 'my-app'});
      expect(twice, once);
    });

    test('a null entry deletes the key the caller no longer wants', () {
      final existing = '$_pubspec\nsentry:\n'
          '  url: https://sentry.internal\n'
          '  org: my-org\n';
      final updated = PubspecText.ensureTopLevelBlock(
          existing, 'sentry', {'org': 'my-org', 'url': null});
      expect(updated, isNot(contains('sentry.internal')));
      expect(loadYaml(updated)['sentry'], {'org': 'my-org'});
    });

    test('a null entry for an absent key changes nothing', () {
      final updated = PubspecText.ensureTopLevelBlock(
          '$_pubspec\nsentry:\n  org: my-org\n', 'sentry', {'url': null});
      expect(updated, '$_pubspec\nsentry:\n  org: my-org\n');
    });

    test('null-only entries never create the block', () {
      expect(
          PubspecText.ensureTopLevelBlock(_pubspec, 'sentry', {'url': null}),
          _pubspec);
    });

    test('hasTopLevelBlock sees block and flow style alike', () {
      expect(PubspecText.hasTopLevelBlock('$_pubspec\nsentry:\n  org: x\n',
          'sentry'), isTrue);
      expect(PubspecText.hasTopLevelBlock('$_pubspec\nsentry: { org: x }\n',
          'sentry'), isTrue);
      expect(PubspecText.hasTopLevelBlock(_pubspec, 'sentry'), isFalse);
    });

    test('flow style is reported with the block to paste', () {
      expect(
        () => PubspecText.ensureTopLevelBlock(
            'name: app\nsentry: { org: my-org }\n', 'sentry', {'org': 'x'}),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('flow style'))
            .having((e) => e.message, 'message', contains('  org: x'))),
      );
    });

    test('trailing whitespace on the block line is not flow style', () {
      final updated = PubspecText.ensureTopLevelBlock(
          'name: app\nsentry:   \n  org: old\n', 'sentry', {'org': 'new'});
      expect(updated, contains('  org: new\n'));
    });

    test('a comment on the block line is not flow style', () {
      final updated = PubspecText.ensureTopLevelBlock(
          'name: app\nsentry: # error monitoring\n  org: old\n',
          'sentry',
          {'org': 'new'});
      expect(updated, contains('sentry: # error monitoring\n  org: new\n'));
    });
  });

  group('ensurePubDependency', () {
    late Directory tempDir;
    late StringBuffer out;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('pubspec_text_test');
      out = StringBuffer();
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    void writePubspec([String content = _pubspec]) =>
        File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync(content);

    SetupContext context({
      ProcessRunner? processes,
      bool dryRun = false,
    }) =>
        SetupContext(
          projectRoot: tempDir.path,
          config: ProjectConfig.fromYaml(
              loadYaml('app: { name: X, bundle_id: com.x }') as Map),
          env: const {},
          processes: processes,
          dryRun: dryRun,
          out: out,
        );

    test('an already listed package is left alone', () async {
      writePubspec();
      final processes = _PubProcessRunner();
      expect(await ensurePubDependency(context(processes: processes), 'path'),
          isTrue);
      expect(processes.streamed, isEmpty);
      expect(out.toString(), contains('already in pubspec.yaml'));
    });

    test('a missing package is added with flutter pub add', () async {
      writePubspec();
      final processes = _PubProcessRunner();
      expect(
          await ensurePubDependency(
              context(processes: processes), 'sentry_flutter'),
          isTrue);
      expect(processes.streamed.single.$1, 'flutter');
      expect(processes.streamed.single.$2, ['pub', 'add', 'sentry_flutter']);
    });

    test('a dev dependency keeps its dev: prefix', () async {
      writePubspec();
      final processes = _PubProcessRunner();
      await ensurePubDependency(
          context(processes: processes), 'sentry_dart_plugin',
          dev: true);
      expect(processes.streamed.single.$2,
          ['pub', 'add', 'dev:sentry_dart_plugin']);
    });

    test('dry-run only says what it would add', () async {
      writePubspec();
      final processes = _PubProcessRunner();
      await ensurePubDependency(
          context(processes: processes, dryRun: true), 'sentry_flutter');
      expect(processes.streamed, isEmpty);
      expect(out.toString(), contains('[dry-run]'));
    });

    test('no flutter on PATH is a warning, not a failure', () async {
      writePubspec();
      expect(
          await ensurePubDependency(
              context(processes: _PubProcessRunner(flutterInstalled: false)),
              'sentry_flutter'),
          isFalse);
      expect(out.toString(), contains('flutter not found'));
    });

    test('a failed pub add says to add it by hand', () async {
      writePubspec();
      expect(
          await ensurePubDependency(
              context(processes: _PubProcessRunner(addExitCode: 66)),
              'sentry_flutter'),
          isFalse);
      expect(out.toString(), contains('add it to pubspec.yaml yourself'));
    });

    test('a project without a pubspec is reported', () async {
      expect(
          await ensurePubDependency(context(), 'sentry_flutter'), isFalse);
      expect(out.toString(), contains('No pubspec.yaml'));
    });
  });
}
