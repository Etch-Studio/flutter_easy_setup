import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('easy_setup_init_test');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<int> runInit({bool force = false, bool dryRun = false}) =>
      InitCommand.run(
        directory: tempDir.path,
        appName: 'Dream Diary',
        bundleId: 'studio.etch.dreamdiary',
        packageName: 'studio.etch.dreamdiary',
        force: force,
        dryRun: dryRun,
        out: out,
      );

  group('InitCommand', () {
    test('creates easy_setup.yaml and the asset skeleton', () async {
      final exitCode = await runInit();
      expect(exitCode, 0);

      final configFile = File(p.join(tempDir.path, 'easy_setup.yaml'));
      expect(configFile.existsSync(), isTrue);
      for (final dir in InitCommand.assetDirectories) {
        expect(Directory(p.join(tempDir.path, dir)).existsSync(), isTrue);
        expect(File(p.join(tempDir.path, dir, '.gitkeep')).existsSync(),
            isTrue);
      }
      expect(out.toString(), contains('easy_setup doctor'));
    });

    test('monorepo: workflow goes to the git root with project-root wired',
        () async {
      Directory(p.join(tempDir.path, '.git')).createSync();
      final appDir = Directory(p.join(tempDir.path, 'apps', 'app'))
        ..createSync(recursive: true);
      await InitCommand.run(
        directory: appDir.path,
        appName: 'X',
        bundleId: 'com.x',
        out: out,
      );
      final workflow =
          File(p.join(tempDir.path, InitCommand.workflowPath));
      expect(workflow.existsSync(), isTrue);
      final content = workflow.readAsStringSync();
      expect(content, contains("project-root: 'apps/app'"));
      // Both jobs carry the input.
      expect('project-root:'.allMatches(content), hasLength(2));
      // The app skeleton still lands in the app directory.
      expect(File(p.join(appDir.path, 'easy_setup.yaml')).existsSync(),
          isTrue);
    });

    test('monorepo: an existing workflow is kept but the hint names the '
        'required project-root', () async {
      Directory(p.join(tempDir.path, '.git')).createSync();
      final appDir = Directory(p.join(tempDir.path, 'apps', 'app'))
        ..createSync(recursive: true);
      File(p.join(tempDir.path, InitCommand.workflowPath))
        ..createSync(recursive: true)
        ..writeAsStringSync('# custom\n');
      await InitCommand.run(
        directory: appDir.path,
        appName: 'X',
        bundleId: 'com.x',
        out: out,
      );
      expect(out.toString(), contains("project-root: 'apps/app'"));
      expect(File(p.join(tempDir.path, InitCommand.workflowPath))
              .readAsStringSync(),
          '# custom\n');
    });

    test('single repo: workflow at the root without a project-root input',
        () async {
      Directory(p.join(tempDir.path, '.git')).createSync();
      await runInit();
      final content = File(p.join(tempDir.path, InitCommand.workflowPath))
          .readAsStringSync();
      expect(content, isNot(contains('project-root:')));
    });

    test('generates the caller release workflow, keeping an existing one',
        () async {
      await runInit();
      final workflow =
          File(p.join(tempDir.path, InitCommand.workflowPath));
      expect(workflow.existsSync(), isTrue);
      expect(workflow.readAsStringSync(), contains('release-ios.yml'));
      expect(workflow.readAsStringSync(), contains('secrets: inherit'));

      workflow.writeAsStringSync('# custom\n');
      await runInit(force: true);
      expect(workflow.readAsStringSync(), '# custom\n');
      expect(out.toString(), contains('already exists'));
    });

    test('generated template parses as a valid v2 config', () async {
      await runInit();
      final config = ProjectConfig.fromFile(
          p.join(tempDir.path, 'easy_setup.yaml'));
      expect(config.app.name, 'Dream Diary');
      expect(config.app.bundleId, 'studio.etch.dreamdiary');
      // Optional sections ship commented out.
      expect(config.ios, isNull);
      expect(config.flavors, isEmpty);
    });

    test('refuses to overwrite without --force', () async {
      await runInit();
      expect(
        runInit,
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('--force'))),
      );
    });

    test('overwrites with --force', () async {
      await runInit();
      final exitCode = await runInit(force: true);
      expect(exitCode, 0);
    });

    test('dry-run creates nothing', () async {
      final exitCode = await runInit(dryRun: true);
      expect(exitCode, 0);
      expect(File(p.join(tempDir.path, 'easy_setup.yaml')).existsSync(),
          isFalse);
      expect(
          Directory(p.join(tempDir.path, 'assets')).existsSync(), isFalse);
      expect(out.toString(), contains('[dry-run]'));
    });

    test('app name containing YAML syntax survives the template', () {
      final template = InitCommand.template(
        appName: "Kids: Learn & Play #1 (it's fun)",
        bundleId: 'com.example.kids',
        packageName: 'com.example.kids',
      );
      final config = ProjectConfig.fromYaml(loadYaml(template) as Map);
      expect(config.app.name, "Kids: Learn & Play #1 (it's fun)");
    });

    test('template with placeholders is itself a valid v2 config', () {
      final template = InitCommand.template(
        appName: 'MyApp',
        bundleId: 'com.example.myapp',
        packageName: 'com.example.myapp',
      );
      final config = ProjectConfig.fromYaml(loadYaml(template) as Map);
      expect(config.app.name, 'MyApp');
    });
  });
}
