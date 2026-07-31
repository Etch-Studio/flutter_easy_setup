import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String path;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('env_json_writer_test');
    path = p.join(tempDir.path, 'env.json');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('EnvJsonWriter', () {
    test('creates the file when missing', () {
      final changed = EnvJsonWriter.merge(path, {'A': '1'});
      expect(changed, isTrue);
      expect(json.decode(File(path).readAsStringSync()), {'A': '1'});
    });

    test('preserves keys it does not own', () {
      File(path).writeAsStringSync('{"KEEP": "me", "A": "old"}');
      EnvJsonWriter.merge(path, {'A': 'new'});
      expect(json.decode(File(path).readAsStringSync()),
          {'KEEP': 'me', 'A': 'new'});
    });

    test('reports unchanged when values already match', () {
      File(path).writeAsStringSync('{"A": "1"}');
      expect(EnvJsonWriter.merge(path, {'A': '1'}), isFalse);
    });

    test('dry-run reports the change without writing', () {
      final changed = EnvJsonWriter.merge(path, {'A': '1'}, dryRun: true);
      expect(changed, isTrue);
      expect(File(path).existsSync(), isFalse);
    });

    test('ownedPrefix removes stale owned keys, keeps foreign ones', () {
      File(path).writeAsStringSync(
          '{"ADMOB_OLD": "x", "ADMOB_KEPT": "old", "OTHER": "y"}');
      final changed = EnvJsonWriter.merge(path, {'ADMOB_KEPT': 'new'},
          ownedPrefix: 'ADMOB_');
      expect(changed, isTrue);
      expect(json.decode(File(path).readAsStringSync()),
          {'ADMOB_KEPT': 'new', 'OTHER': 'y'});
    });

    test('rejects invalid JSON with a clear error', () {
      File(path).writeAsStringSync('not json');
      expect(
        () => EnvJsonWriter.merge(path, {'A': '1'}),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('not valid JSON'))),
      );
    });
  });
}
