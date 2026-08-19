import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('dart_define'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config([String extra = '']) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
$extra
''') as Map);

  void writeEnv(String name) => File(p.join(tempDir.path, name))
      .writeAsStringSync('{"SENTRY_DSN": "https://k@o1.ingest/1"}');

  group('DartDefineFile.resolve', () {
    test('picks up env.prod.json without any config', () {
      writeEnv('env.prod.json');
      expect(
        DartDefineFile.resolve(
            projectRoot: tempDir.path, config: config('sentry: { org: o }')),
        'env.prod.json',
      );
    });

    test('is null when the project has no env file', () {
      expect(
        DartDefineFile.resolve(projectRoot: tempDir.path, config: config()),
        isNull,
      );
    });

    test('an explicit file is used', () {
      writeEnv('env.store.json');
      expect(
        DartDefineFile.resolve(
          projectRoot: tempDir.path,
          config: config('build: { dart_define_file: env.store.json }'),
        ),
        'env.store.json',
      );
    });

    test('an explicit file that is missing fails loudly', () {
      // Falling back here would ship the silent build this class prevents.
      writeEnv('env.prod.json');
      expect(
        () => DartDefineFile.resolve(
          projectRoot: tempDir.path,
          config: config('build: { dart_define_file: env.store.json }'),
        ),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('env.store.json'))),
      );
    });
  });

  group('DartDefineFile.arguments', () {
    test('is the flutter flag, or nothing at all', () {
      expect(DartDefineFile.arguments('env.prod.json'),
          ['--dart-define-from-file=env.prod.json']);
      expect(DartDefineFile.arguments(null), isEmpty);
    });
  });

  group('DartDefineFile.missingNote', () {
    test('names the steps whose values would be empty', () {
      final note = DartDefineFile.missingNote(
          config('sentry: { org: o }\namplitude:'))!;
      expect(note, contains('sentry / amplitude'));
      expect(note, contains('env.prod.json'));
    });

    test('stays quiet when nothing writes defines', () {
      expect(DartDefineFile.missingNote(config()), isNull);
    });
  });
}
