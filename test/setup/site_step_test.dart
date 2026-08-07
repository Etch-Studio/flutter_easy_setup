import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('site_step_test');
    out = StringBuffer();
    // A git repo with a GitHub remote so the Pages URL can be derived.
    Directory(p.join(tempDir.path, '.git')).createSync();
    File(p.join(tempDir.path, '.git', 'config')).writeAsStringSync('''
[remote "origin"]
	url = https://github.com/lwbvv/dream-diary.git
''');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config([String siteSection = 'site: {}']) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: Dream Diary, bundle_id: studio.etch.dd }
$siteSection
''') as Map);

  SetupContext context({ProjectConfig? cfg, bool dryRun = false}) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: const {},
        dryRun: dryRun,
        out: out,
      );

  void writeStoreInfo(String content) =>
      File(p.join(tempDir.path, StoreInfoConfig.fileName))
          .writeAsStringSync(content);

  String siteFile(String name) =>
      File(p.join(tempDir.path, SiteStep.siteDirName, name))
          .readAsStringSync();

  group('SiteStep', () {
    test('is configured only with a site section', () {
      expect(
          SiteStep().isConfigured(ProjectConfig.fromYaml(
              loadYaml('app: { name: X, bundle_id: com.x }') as Map)),
          isFalse);
      expect(SiteStep().isConfigured(config()), isTrue);
    });

    test('generates the three pages, stylesheet, brief, skill, workflow',
        () async {
      await SiteStep().run(context());
      for (final name in [
        'index.html',
        'support.html',
        'privacy.html',
        'style.css',
        SiteStep.briefFileName,
      ]) {
        expect(
            File(p.join(tempDir.path, SiteStep.siteDirName, name))
                .existsSync(),
            isTrue,
            reason: name);
      }
      expect(File(p.join(tempDir.path, SiteStep.skillRelativePath))
          .existsSync(), isTrue);
      final workflow = File(p.join(tempDir.path, SiteStep.workflowRelativePath));
      expect(workflow.existsSync(), isTrue);
      expect(workflow.readAsStringSync(), contains('upload-pages-artifact'));
      // Nav links between the pages resolve.
      expect(siteFile('index.html'), contains('href="support.html"'));
      expect(siteFile('support.html'), contains('href="privacy.html"'));
    });

    test('pulls copy from the store info file', () async {
      writeStoreInfo('''
review_information: { email_address: dev@etch.studio }
locales:
  ko:
    name: 드림로그
    subtitle: 꿈을 기록하는
    description: 매일 아침 꿈을 기록하세요.
''');
      await SiteStep().run(context(
          cfg: config('site: { features: [빠른 기록, 감정 태그] }')));
      final index = siteFile('index.html');
      expect(index, contains('드림로그'));
      expect(index, contains('꿈을 기록하는'));
      expect(index, contains('빠른 기록'));
      expect(index, contains('lang="ko"'));
      expect(siteFile('support.html'), contains('dev@etch.studio'));
    });

    test('never overwrites an edited page, but refreshes the brief',
        () async {
      await SiteStep().run(context());
      final index = File(p.join(tempDir.path, SiteStep.siteDirName,
          'index.html'))
        ..writeAsStringSync('<html>my redesign</html>');

      await SiteStep()
          .run(context(cfg: config('site: { tagline: new tagline }')));
      expect(index.readAsStringSync(), '<html>my redesign</html>');
      // The brief is derived data and does update.
      expect(siteFile(SiteStep.briefFileName), contains('new tagline'));
    });

    test('writes the derived Pages URLs into the store info file',
        () async {
      writeStoreInfo('''
locales:
  ko:
    name: 드림로그
''');
      await SiteStep().run(context());
      final storeInfo =
          File(p.join(tempDir.path, StoreInfoConfig.fileName))
              .readAsStringSync();
      expect(storeInfo,
          contains('support_url: https://lwbvv.github.io/dream-diary/support.html'));
      expect(storeInfo, contains('privacy_url:'));
      // Parses back cleanly.
      final parsed = StoreInfoConfig.fromFile(
          p.join(tempDir.path, StoreInfoConfig.fileName));
      expect(parsed.locales['ko']!['marketing_url'],
          'https://lwbvv.github.io/dream-diary/');
    });

    test('existing store URLs are preserved', () async {
      writeStoreInfo('''
locales:
  ko:
    name: 드림로그
    support_url: https://my.site/help
''');
      await SiteStep().run(context());
      final parsed = StoreInfoConfig.fromFile(
          p.join(tempDir.path, StoreInfoConfig.fileName));
      expect(parsed.locales['ko']!['support_url'], 'https://my.site/help');
      // The others were still added.
      expect(parsed.locales['ko']!['privacy_url'], isNotNull);
    });

    test('site.base_url overrides the derived URL', () async {
      writeStoreInfo('''
locales:
  ko:
    name: 드림로그
''');
      await SiteStep()
          .run(context(cfg: config('site: { base_url: https://dream.app/ }')));
      final parsed = StoreInfoConfig.fromFile(
          p.join(tempDir.path, StoreInfoConfig.fileName));
      expect(parsed.locales['ko']!['support_url'],
          'https://dream.app/support.html');
    });

    test('every store locale gets URLs, not just the first', () async {
      writeStoreInfo('''
locales:
  ko:
    name: 드림로그
  en-US:
    name: Dream Diary
''');
      await SiteStep().run(context());
      final parsed = StoreInfoConfig.fromFile(
          p.join(tempDir.path, StoreInfoConfig.fileName));
      for (final locale in ['ko', 'en-US']) {
        expect(parsed.locales[locale]!['support_url'], isNotNull,
            reason: locale);
        expect(parsed.locales[locale]!['privacy_url'], isNotNull,
            reason: locale);
      }
    });

    test('user/org Pages repos resolve to the root URL', () async {
      File(p.join(tempDir.path, '.git', 'config')).writeAsStringSync('''
[remote "origin"]
	url = https://github.com/lwbvv/lwbvv.github.io.git
''');
      writeStoreInfo('locales:\n  ko:\n    name: X\n');
      await SiteStep().run(context());
      final parsed = StoreInfoConfig.fromFile(
          p.join(tempDir.path, StoreInfoConfig.fileName));
      expect(parsed.locales['ko']!['marketing_url'],
          'https://lwbvv.github.io/');
    });

    test('a dotted repo name keeps its dots', () async {
      File(p.join(tempDir.path, '.git', 'config')).writeAsStringSync('''
[remote "origin"]
	url = git@github.com:lwbvv/my.app.git
''');
      writeStoreInfo('locales:\n  ko:\n    name: X\n');
      await SiteStep().run(context());
      final parsed = StoreInfoConfig.fromFile(
          p.join(tempDir.path, StoreInfoConfig.fileName));
      expect(parsed.locales['ko']!['support_url'],
          'https://lwbvv.github.io/my.app/support.html');
    });

    test('user text is HTML-escaped and unsafe URLs are dropped', () async {
      writeStoreInfo('''
locales:
  ko:
    name: '<script>alert(1)</script>'
''');
      await SiteStep().run(context(
          cfg: config('''
site:
  features: ['<img src=x onerror=alert(1)>']
  app_store_url: 'javascript:alert(1)'
''')));
      final index = siteFile('index.html');
      // Escaped to inert text, not parsed as markup.
      expect(index, isNot(contains('<script>alert')));
      expect(index, contains('&lt;script&gt;'));
      expect(index, isNot(contains('<img src=x')));
      expect(index, contains('&lt;img src=x'));
      // A javascript: store link is dropped rather than rendered.
      expect(index, isNot(contains('javascript:')));
    });

    test('a flow-style locale block is reported instead of corrupted',
        () async {
      // The writer is line-based; inline YAML is left untouched and the
      // URLs are printed for the user to paste.
      writeStoreInfo('locales: { ko: { name: 드림로그 } }');
      await SiteStep().run(context());
      final unchanged =
          File(p.join(tempDir.path, StoreInfoConfig.fileName))
              .readAsStringSync();
      expect(unchanged.trim(), 'locales: { ko: { name: 드림로그 } }');
      expect(out.toString(), contains('add these manually'));
      expect(out.toString(), contains('support_url'));
    });

    test('the brief lists configured SDKs for the privacy page', () async {
      final cfg = ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
sentry: { org: o }
admob: {}
site: { mood: warm and retro }
''') as Map);
      await SiteStep().run(context(cfg: cfg));
      final brief = siteFile(SiteStep.briefFileName);
      expect(brief, contains('Sentry'));
      expect(brief, contains('AdMob'));
      expect(brief, contains('warm and retro'));
    });

    test('dry-run creates nothing', () async {
      await SiteStep().run(context(dryRun: true));
      expect(Directory(p.join(tempDir.path, SiteStep.siteDirName))
          .existsSync(), isFalse);
      expect(out.toString(), contains('[dry-run]'));
    });
  });
}
