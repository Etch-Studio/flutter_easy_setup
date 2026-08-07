import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

class StoreFakeProcessRunner extends ProcessRunner {
  final streamed = <(String, List<String>)>[];

  @override
  Future<int> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    streamed.add((executable, arguments));
    return 0;
  }
}

const _ascEnv = {
  'ASC_KEY_ID': 'KEY123',
  'ASC_ISSUER_ID': 'issuer-uuid',
  'ASC_KEY_P8': '-----BEGIN PRIVATE KEY-----',
};

const _storeInfo = '''
copyright: 2026 Etch Studio
primary_category: LIFESTYLE
locales:
  ko:
    name: 드림로그
    subtitle: 꿈을 기록하는
    description: 매일 아침 꿈을 기록하세요.
    keywords: 꿈,일기,해몽
    short_description: 꿈 일기
    release_notes: 버그 수정
    support_url: https://etch.studio/support
''';

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('store_step_test');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  void writeStoreInfo([String content = _storeInfo]) =>
      File(p.join(tempDir.path, StoreInfoConfig.fileName))
          .writeAsStringSync(content);

  ProjectConfig config({bool android = false}) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x, package_name: com.x }
${android ? 'android: { play_track_default: beta }' : ''}
''') as Map);

  SetupContext context({
    ProjectConfig? cfg,
    Map<String, String> env = const {},
    StoreFakeProcessRunner? processes,
    bool dryRun = false,
  }) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: env,
        processes: processes ?? StoreFakeProcessRunner(),
        dryRun: dryRun,
        out: out,
      );

  group('StoreInfoConfig', () {
    test('rejects an over-limit field with the store limit named', () {
      expect(
        () => StoreInfoConfig.fromYaml(
            loadYaml('''
locales:
  ko: { name: '${'가' * 31}' }
''') as Map,
            'f.yaml'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('limit is 30'))),
      );
    });

    test('rejects unknown fields with the allowed list', () {
      expect(
        () => StoreInfoConfig.fromYaml(
            loadYaml('locales: { ko: { name: X, bogus: y } }') as Map,
            'f.yaml'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('bogus'))),
      );
    });

    test('requires name per locale and at least one locale', () {
      expect(
        () => StoreInfoConfig.fromYaml(
            loadYaml('locales: { ko: { description: x } }') as Map, 'f.yaml'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('name'))),
      );
      expect(
        () => StoreInfoConfig.fromYaml(
            loadYaml('copyright: x') as Map, 'f.yaml'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('locales'))),
      );
    });
  });

  group('StoreStep', () {
    test('is active only when the store info file exists', () {
      final step = StoreStep();
      expect(step.isActive(context()), isFalse);
      writeStoreInfo();
      expect(step.isActive(context()), isTrue);
      expect(step.configurationHint, contains(StoreInfoConfig.fileName));
    });

    test('review_information generates deliver files and is never pruned',
        () async {
      writeStoreInfo('''
review_information:
  first_name: Chiwon
  email_address: dev@etch.studio
locales:
  ko: { name: 드림로그, short_description: 꿈 일기 }
''');
      await StoreStep().run(context());
      final reviewDir = p.join(
          tempDir.path, 'fastlane', 'metadata', 'review_information');
      expect(File(p.join(reviewDir, 'first_name.txt')).readAsStringSync(),
          'Chiwon\n');
      expect(File(p.join(reviewDir, 'email_address.txt')).existsSync(),
          isTrue);
      // A second run does not misread the dir as a stale locale.
      out.clear();
      await StoreStep().run(context());
      expect(out.toString(), isNot(contains('unmanaged files')));
      expect(Directory(reviewDir).existsSync(), isTrue);
    });

    test('review_information without a +phone warns (ASC hard requirement)',
        () async {
      writeStoreInfo('''
review_information: { first_name: Chiwon }
locales:
  ko: { name: 드림로그, short_description: 꿈 일기 }
''');
      await StoreStep().run(context());
      expect(out.toString(), contains('phone_number'));
      expect(out.toString(), contains('rejects the review detail'));
    });

    test('missing review_information warns about the first deliver run',
        () async {
      writeStoreInfo();
      await StoreStep().run(context());
      expect(out.toString(), contains("'review_information' is empty"));
    });

    test('rejects unknown review_information keys', () {
      expect(
        () => StoreInfoConfig.fromYaml(
            loadYaml('''
review_information: { fax: '123' }
locales: { ko: { name: X } }
''') as Map,
            'f.yaml'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('fax'))),
      );
    });

    test('generates both fastlane trees from the one source', () async {
      writeStoreInfo();
      await StoreStep().run(context());

      final metadata = p.join(tempDir.path, 'fastlane', 'metadata');
      expect(File(p.join(metadata, 'copyright.txt')).readAsStringSync(),
          '2026 Etch Studio\n');
      expect(
          File(p.join(metadata, 'primary_category.txt')).existsSync(), isTrue);
      expect(File(p.join(metadata, 'ko', 'name.txt')).readAsStringSync(),
          '드림로그\n');
      expect(File(p.join(metadata, 'ko', 'keywords.txt')).existsSync(),
          isTrue);

      final android = p.join(metadata, 'android', 'ko');
      expect(File(p.join(android, 'title.txt')).readAsStringSync(),
          '드림로그\n');
      expect(File(p.join(android, 'short_description.txt')).existsSync(),
          isTrue);
      expect(File(p.join(android, 'full_description.txt')).existsSync(),
          isTrue);
      expect(
          File(p.join(android, 'changelogs', 'default.txt')).existsSync(),
          isTrue);
    });

    test('a removed field removes its generated file (convergence)',
        () async {
      writeStoreInfo();
      await StoreStep().run(context());
      final keywords = File(
          p.join(tempDir.path, 'fastlane', 'metadata', 'ko', 'keywords.txt'));
      expect(keywords.existsSync(), isTrue);

      writeStoreInfo('''
locales:
  ko: { name: 드림로그 }
''');
      await StoreStep().run(context());
      expect(keywords.existsSync(), isFalse);
      expect(out.toString(), contains('short_description'));
    });

    test('release notes over Play\'s 500-char cap skip the changelog',
        () async {
      writeStoreInfo('''
locales:
  ko:
    name: 드림로그
    release_notes: '${'가' * 501}'
''');
      await StoreStep().run(context());
      expect(
          File(p.join(tempDir.path, 'fastlane', 'metadata', 'android', 'ko',
                  'changelogs', 'default.txt'))
              .existsSync(),
          isFalse);
      // iOS keeps the long notes (its cap is 4000).
      expect(
          File(p.join(tempDir.path, 'fastlane', 'metadata', 'ko',
                  'release_notes.txt'))
              .existsSync(),
          isTrue);
      expect(out.toString(), contains('caps release notes at 500'));
    });

    test('a removed locale prunes its trees, foreign files survive',
        () async {
      writeStoreInfo('''
locales:
  ko: { name: 드림로그 }
  en-US: { name: Dream Diary }
''');
      await StoreStep().run(context());
      final enDir =
          Directory(p.join(tempDir.path, 'fastlane', 'metadata', 'en-US'));
      expect(enDir.existsSync(), isTrue);

      writeStoreInfo('locales: { ko: { name: 드림로그 } }');
      await StoreStep().run(context());
      expect(enDir.existsSync(), isFalse);
      expect(
          Directory(p.join(
                  tempDir.path, 'fastlane', 'metadata', 'android', 'en-US'))
              .existsSync(),
          isFalse);

      // A locale dir with an unmanaged file is warned about, not deleted.
      final custom =
          Directory(p.join(tempDir.path, 'fastlane', 'metadata', 'ja'))
            ..createSync(recursive: true);
      File(p.join(custom.path, 'review_notes.txt')).writeAsStringSync('x');
      await StoreStep().run(context());
      expect(custom.existsSync(), isTrue);
      expect(out.toString(), contains('unmanaged files'));
    });

    test('uploads via deliver when the ASC key is set', () async {
      writeStoreInfo();
      final processes = StoreFakeProcessRunner();
      await StoreStep().run(context(env: _ascEnv, processes: processes));

      final deliver = processes.streamed.single;
      expect(deliver.$1, 'fastlane');
      expect(deliver.$2.first, 'deliver');
      expect(deliver.$2,
          containsAllInOrder(['--skip_binary_upload', 'true']));
      expect(deliver.$2, containsAllInOrder(['--app_identifier', 'com.x']));
      // No screenshots directory → screenshots skipped.
      expect(deliver.$2, containsAllInOrder(['--skip_screenshots', 'true']));
      expect(out.toString(), contains('App Store listing updated'));
    });

    test('includes screenshots when the M5 pipeline produced them',
        () async {
      writeStoreInfo();
      Directory(p.join(tempDir.path, 'fastlane', 'screenshots', 'ko'))
          .createSync(recursive: true);
      final processes = StoreFakeProcessRunner();
      await StoreStep().run(context(env: _ascEnv, processes: processes));
      expect(processes.streamed.single.$2,
          containsAllInOrder(['--screenshots_path', 'fastlane/screenshots']));
      // Local pruning must mirror remotely.
      expect(processes.streamed.single.$2,
          containsAllInOrder(['--overwrite_screenshots', 'true']));
    });

    test('without the ASC key it generates but skips the upload', () async {
      writeStoreInfo();
      final processes = StoreFakeProcessRunner();
      await StoreStep().run(context(processes: processes));
      expect(processes.streamed, isEmpty);
      expect(out.toString(), contains('skipped the App Store upload'));
    });

    test('uploads the Play listing when android is configured', () async {
      writeStoreInfo();
      final processes = StoreFakeProcessRunner();
      await StoreStep().run(context(
        cfg: config(android: true),
        env: {..._ascEnv, 'PLAY_SERVICE_ACCOUNT_JSON': '{"client_email":"x"}'},
        processes: processes,
      ));
      final supply =
          processes.streamed.firstWhere((c) => c.$2.first == 'supply').$2;
      expect(supply, containsAllInOrder(['--skip_upload_aab', 'true']));
      expect(supply, containsAllInOrder(['--skip_upload_metadata', 'false']));
      expect(supply, containsAllInOrder(['--package_name', 'com.x']));
    });

    test('dry-run previews without writing or calling anything', () async {
      writeStoreInfo();
      final processes = StoreFakeProcessRunner();
      await StoreStep()
          .run(context(env: _ascEnv, processes: processes, dryRun: true));
      expect(processes.streamed, isEmpty);
      expect(
          Directory(p.join(tempDir.path, 'fastlane')).existsSync(), isFalse);
      expect(out.toString(), contains('[dry-run]'));
    });
  });
}
