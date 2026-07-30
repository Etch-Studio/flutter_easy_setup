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
