import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String projectRoot;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('firebase_opts_gen_test_');
    projectRoot = tempDir.path;
    Directory(p.join(projectRoot, 'lib')).createSync(recursive: true);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('FirebaseOptionsGenerator', () {
    test('generates firebase_options.dart with multiple flavors', () {
      FirebaseOptionsGenerator.generate(projectRoot, ['dev', 'prod']);

      final file = File(p.join(projectRoot, 'lib', 'firebase_options.dart'));
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content, contains("import 'firebase_options_dev.dart'"));
      expect(content, contains("import 'firebase_options_prod.dart'"));
      expect(content, contains("case 'dev':"));
      expect(content, contains("case 'prod':"));
      expect(content, contains('getFirebaseOptions'));
    });

    test('generates firebase_options.dart with single flavor', () {
      FirebaseOptionsGenerator.generate(projectRoot, ['prod']);

      final content =
          File(p.join(projectRoot, 'lib', 'firebase_options.dart'))
              .readAsStringSync();
      expect(content, contains("case 'prod':"));
      expect(content, isNot(contains("case 'dev':")));
    });

    test('includes error message with available flavors', () {
      FirebaseOptionsGenerator.generate(projectRoot, ['dev', 'staging', 'prod']);

      final content =
          File(p.join(projectRoot, 'lib', 'firebase_options.dart'))
              .readAsStringSync();
      expect(content, contains('Available flavors: dev, staging, prod'));
    });

    test('does not write file in dry-run mode', () {
      FirebaseOptionsGenerator.generate(projectRoot, ['dev'], dryRun: true);

      final file = File(p.join(projectRoot, 'lib', 'firebase_options.dart'));
      expect(file.existsSync(), isFalse);
    });

    test('overwrites existing file (idempotent)', () {
      FirebaseOptionsGenerator.generate(projectRoot, ['dev']);
      final first =
          File(p.join(projectRoot, 'lib', 'firebase_options.dart'))
              .readAsStringSync();

      FirebaseOptionsGenerator.generate(projectRoot, ['dev', 'prod']);
      final second =
          File(p.join(projectRoot, 'lib', 'firebase_options.dart'))
              .readAsStringSync();

      expect(second, isNot(equals(first)));
      expect(second, contains("case 'prod':"));
    });
  });
}
