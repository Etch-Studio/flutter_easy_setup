import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String projectRoot;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xcodegen_scripts_test_');
    projectRoot = tempDir.path;
    Directory(p.join(projectRoot, 'ios')).createSync(recursive: true);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('XcodeGenScriptsGenerator', () {
    test('generates run_script.sh and thin_binary.sh', () {
      XcodeGenScriptsGenerator.generate(projectRoot);

      final runScript = File(
          p.join(projectRoot, 'ios', 'xcodegen', 'script', 'run_script.sh'));
      final thinScript = File(
          p.join(projectRoot, 'ios', 'xcodegen', 'script', 'thin_binary.sh'));

      expect(runScript.existsSync(), isTrue);
      expect(thinScript.existsSync(), isTrue);
    });

    test('run_script.sh calls xcode_backend.sh build', () {
      XcodeGenScriptsGenerator.generate(projectRoot);

      final content = File(
              p.join(projectRoot, 'ios', 'xcodegen', 'script', 'run_script.sh'))
          .readAsStringSync();

      expect(content, contains('xcode_backend.sh'));
      expect(content, contains('build'));
    });

    test('thin_binary.sh calls xcode_backend.sh embed_and_thin', () {
      XcodeGenScriptsGenerator.generate(projectRoot);

      final content = File(p.join(
              projectRoot, 'ios', 'xcodegen', 'script', 'thin_binary.sh'))
          .readAsStringSync();

      expect(content, contains('xcode_backend.sh'));
      expect(content, contains('embed_and_thin'));
    });

    test('does not write files in dry-run mode', () {
      XcodeGenScriptsGenerator.generate(projectRoot, dryRun: true);

      final scriptsDir =
          Directory(p.join(projectRoot, 'ios', 'xcodegen', 'script'));
      expect(scriptsDir.existsSync(), isFalse);
    });

    test('generates copy_firebase_plist.sh when firebaseFlavors is provided', () {
      XcodeGenScriptsGenerator.generate(projectRoot,
          firebaseFlavors: ['dev', 'prod']);

      final script = File(p.join(
          projectRoot, 'ios', 'xcodegen', 'script', 'copy_firebase_plist.sh'));
      expect(script.existsSync(), isTrue);

      final content = script.readAsStringSync();
      expect(content, contains('FLAVOR='));
      expect(content, contains('[ "\$FLAVOR" = "dev" ]'));
      expect(content, contains('[ "\$FLAVOR" = "prod" ]'));
      expect(content, contains('GoogleService-Info.plist'));
    });

    test('copy_firebase_plist.sh uses exact matching, not substring', () {
      XcodeGenScriptsGenerator.generate(projectRoot,
          firebaseFlavors: ['dev', 'develop']);

      final content = File(p.join(
              projectRoot, 'ios', 'xcodegen', 'script', 'copy_firebase_plist.sh'))
          .readAsStringSync();

      // Should use exact match (= not ==*), not substring matching
      expect(content, contains('[ "\$FLAVOR" = "dev" ]'));
      expect(content, contains('[ "\$FLAVOR" = "develop" ]'));
      expect(content, isNot(contains('== *')));
    });

    test('does not generate copy_firebase_plist.sh when firebaseFlavors is empty', () {
      XcodeGenScriptsGenerator.generate(projectRoot, firebaseFlavors: []);

      final script = File(p.join(
          projectRoot, 'ios', 'xcodegen', 'script', 'copy_firebase_plist.sh'));
      expect(script.existsSync(), isFalse);
    });

    test('copy_firebase_plist.sh defaults to first flavor', () {
      XcodeGenScriptsGenerator.generate(projectRoot,
          firebaseFlavors: ['dev', 'prod']);

      final content = File(p.join(
              projectRoot, 'ios', 'xcodegen', 'script', 'copy_firebase_plist.sh'))
          .readAsStringSync();

      // Default fallback should use the first flavor
      expect(content, contains('using default (dev)'));
    });

    test('overwrites existing files on re-run (idempotent)', () {
      XcodeGenScriptsGenerator.generate(projectRoot);

      final first = File(
              p.join(projectRoot, 'ios', 'xcodegen', 'script', 'run_script.sh'))
          .readAsStringSync();

      XcodeGenScriptsGenerator.generate(projectRoot);

      final second = File(
              p.join(projectRoot, 'ios', 'xcodegen', 'script', 'run_script.sh'))
          .readAsStringSync();

      expect(second, first);
    });
  });
}
