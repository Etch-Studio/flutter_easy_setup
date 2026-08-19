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

    test('prunes removes stale owned keys, keeps foreign ones', () {
      File(path).writeAsStringSync(
          '{"ADMOB_OLD": "x", "ADMOB_KEPT": "old", "OTHER": "y"}');
      final changed = EnvJsonWriter.merge(path, {'ADMOB_KEPT': 'new'},
          prunes: (key) => key.startsWith('ADMOB_'));
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


  test('an unowned key under the same prefix is never pruned', () {
    final file = File(p.join(tempDir.path, 'env.json'))
      ..writeAsStringSync('{"ADMOB_A_IOS": "keep", "ADMOB_B_IOS": "drop"}');
    final changed = EnvJsonWriter.merge(
      file.path,
      {'ADMOB_C_IOS': 'new'},
      // The caller owns the prefix, except the one key it still declares.
      prunes: (key) => key.startsWith('ADMOB_') && key != 'ADMOB_A_IOS',
    );
    expect(changed, isTrue);
    final env = json.decode(file.readAsStringSync()) as Map;
    // Still declared, value unresolved this run → kept.
    expect(env['ADMOB_A_IOS'], 'keep');
    // No longer declared → pruned.
    expect(env.containsKey('ADMOB_B_IOS'), isFalse);
    expect(env['ADMOB_C_IOS'], 'new');
  });
}
