import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_setup/easy_setup.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../support/fake_html_renderer.dart';

void main() {
  late Directory tempDir;
  late StringBuffer out;
  late FakeHtmlRenderer renderer;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('screenshots_step_test');
    out = StringBuffer();
    renderer = FakeHtmlRenderer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  void writeRaw(String locale, String device, String name,
      {int width = 1290, int height = 2796}) {
    final image = img.Image(width: width, height: height, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(200, 60, 60));
    final file = File(p.join(tempDir.path, ScreenshotsStep.rawRelativeDir,
        locale, device, name))
      ..createSync(recursive: true);
    file.writeAsBytesSync(img.encodePng(image));
  }

  String assetPath(String name) =>
      p.join(tempDir.path, ScreenshotsStep.assetsRelativeDir, name);

  void writeDesign(String yaml) => File(assetPath(
          ScreenshotsStep.designFileName))
    ..createSync(recursive: true)
    ..writeAsStringSync(yaml);

  ProjectConfig config({
    String locales = '[ko]',
    String devices = '[iphone_6_9, android_phone]',
    String extra = '',
  }) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
$extra
screenshots:
  locales: $locales
  devices: $devices
''') as Map);

  SetupContext context(ProjectConfig cfg, {bool dryRun = false}) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg,
        env: const {},
        renderer: renderer,
        dryRun: dryRun,
        out: out,
      );

  /// Decodes the capture the template was handed, after cropping.
  img.Image capturedImage(String html) {
    final match =
        RegExp(r'src="data:image/png;base64,([^"]+)"').firstMatch(html)!;
    return img.decodePng(base64Decode(match.group(1)!))!;
  }

  group('ScreenshotsStep', () {
    test('renders raw captures at the store canvas size per platform',
        () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      writeRaw('ko', 'android_phone', '02_stats.png',
          width: 1080, height: 2400);

      await ScreenshotsStep().run(context(config()));

      expect(renderer.calls.map((call) => (call.width, call.height)),
          [(1320, 2868), (1080, 1920), (1080, 1920)]);

      final ios = File(p.join(tempDir.path, 'fastlane', 'screenshots', 'ko',
          'iphone_6_9_01_home.png'));
      final iosImage = img.decodePng(ios.readAsBytesSync())!;
      expect((iosImage.width, iosImage.height), (1320, 2868));
      // Stores reject assets carrying an alpha channel.
      expect(iosImage.numChannels, 3);

      final android = File(p.join(tempDir.path, 'fastlane', 'metadata',
          'android', 'ko', 'images', 'phoneScreenshots', '02_stats.png'));
      final androidImage = img.decodePng(android.readAsBytesSync())!;
      expect((androidImage.width, androidImage.height), (1080, 1920));

      expect(out.toString(), isNot(contains('at least 2')));
    });

    test('seeds the design sources and the skill, then leaves them alone',
        () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      final cfg = config(devices: '[iphone_6_9]');
      await ScreenshotsStep().run(context(cfg));

      for (final name in [
        ScreenshotsStep.templateFileName,
        ScreenshotsStep.designFileName,
        ScreenshotsStep.featureGraphicTemplateName,
      ]) {
        expect(File(assetPath(name)).existsSync(), isTrue, reason: name);
      }
      final skill =
          File(p.join(tempDir.path, ScreenshotsStep.skillRelativePath));
      expect(skill.existsSync(), isTrue);
      expect(skill.readAsStringSync(), contains('com.x'));

      final template = File(assetPath(ScreenshotsStep.templateFileName))
        ..writeAsStringSync('<html>{{TITLE}}</html>');
      await ScreenshotsStep().run(context(cfg));
      expect(template.readAsStringSync(), '<html>{{TITLE}}</html>');
    });

    test('an unchanged screen is not re-rendered', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      final cfg = config(devices: '[iphone_6_9]');
      await ScreenshotsStep().run(context(cfg));
      expect(renderer.calls, hasLength(1));

      out.clear();
      renderer = FakeHtmlRenderer();
      await ScreenshotsStep().run(context(cfg));
      expect(renderer.calls, isEmpty);
      expect(out.toString(), contains('up to date'));
    });

    test('changed copy re-renders that screen', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      final cfg = config(devices: '[iphone_6_9]');
      await ScreenshotsStep().run(context(cfg));

      writeDesign('''
palettes: { default: { bg: '#000000' } }
defaults: { palette: default }
screens:
  01_home:
    text:
      ko: { title: 꿈을 기록하세요 }
''');
      renderer = FakeHtmlRenderer();
      await ScreenshotsStep().run(context(cfg));
      expect(renderer.calls, hasLength(1));
      expect(renderer.last.html, contains('꿈을 기록하세요'));
    });

    test('copy, palette, and position placeholders reach the template',
        () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      writeRaw('ko', 'iphone_6_9', '02_stats.png');
      File(assetPath(ScreenshotsStep.templateFileName))
        ..createSync(recursive: true)
        ..writeAsStringSync('<p>{{TITLE}}|{{EYEBROW}}|{{C_BG}}|{{C_ACCENT}}'
            '|{{INDEX}}/{{COUNT}}|{{LOCALE}}|{{DEVICE}}|{{SCREEN}}'
            '|{{W}}x{{H}}</p><img src="{{IMG}}">');
      writeDesign('''
palettes:
  night: { bg: '#101010', accent: 'linear-gradient(90deg, #fff, #000)' }
defaults:
  palette: night
  text:
    ko: { eyebrow: 드림로그 }
screens:
  02_stats:
    text:
      ko: { title: 패턴을 발견하세요 }
''');
      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));

      final second = renderer.calls[1].html;
      expect(second, contains('패턴을 발견하세요|드림로그'));
      expect(second, contains('#101010|linear-gradient(90deg, #fff, #000)'));
      expect(second, contains('2/2|ko|iphone_6_9|02_stats|1320x2868'));
    });

    test('copy is escaped, and a newline becomes a line break', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      File(assetPath(ScreenshotsStep.templateFileName))
        ..createSync(recursive: true)
        ..writeAsStringSync('<h1>{{TITLE}}</h1><img src="{{IMG}}">');
      writeDesign('''
screens:
  01_home:
    text:
      ko:
        title: "Tea & <b>toast</b>\\ntwo lines"
''');
      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));
      final html = renderer.last.html;
      // Markup in the copy stays text; the newline becomes a real break.
      expect(html, contains('Tea &amp; &lt;b&gt;toast&lt;&#47;b&gt;<br>two'));
      expect(html, isNot(contains('<b>toast</b>')));
    });

    test('copy that looks like a placeholder is left as written', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      File(assetPath(ScreenshotsStep.templateFileName))
        ..createSync(recursive: true)
        ..writeAsStringSync('<h1>{{TITLE}}</h1><img src="{{IMG}}">');
      writeDesign('''
screens:
  01_home:
    text:
      ko: { title: "use {{TITLE}} in your template" }
''');
      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));
      expect(renderer.last.html,
          contains('<h1>use {{TITLE}} in your template</h1>'));
      expect(out.toString(), isNot(contains('rendered empty')));
    });

    test('crop_bottom trims the capture before it is framed', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png', width: 1000, height: 2000);
      writeDesign('''
defaults: { crop_bottom: 150 }
''');
      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));
      final captured = capturedImage(renderer.last.html);
      expect((captured.width, captured.height), (1000, 1850));
    });

    test('a crop that would erase the capture fails', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png', width: 100, height: 200);
      writeDesign('defaults: { crop_bottom: 500 }');
      await expectLater(
        () => ScreenshotsStep().run(context(config(devices: '[iphone_6_9]'))),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('crop_bottom'))),
      );
    });

    test('fonts are embedded so the render needs no network', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      File(p.join(tempDir.path, 'assets', 'fonts', 'Display.ttf'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([0, 1, 2, 3]);
      File(assetPath(ScreenshotsStep.templateFileName))
        ..createSync(recursive: true)
        ..writeAsStringSync(
            '<style>{{FONT_CSS}}</style><body style="font-family:'
            '{{FONT_FAMILIES}} sans-serif"><img src="{{IMG}}">');
      writeDesign("fonts: { Display: assets/fonts/Display.ttf }");

      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));
      expect(renderer.last.html,
          contains("@font-face { font-family: 'Display';"));
      expect(renderer.last.html, contains('data:font/ttf;base64,AAECAw=='));
      expect(renderer.last.html, contains("font-family:'Display', sans-serif"));
    });

    test('a declared but missing font fails with guidance', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      writeDesign('fonts: { Display: assets/fonts/nope.ttf }');
      await expectLater(
        () => ScreenshotsStep().run(context(config(devices: '[iphone_6_9]'))),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains("Font 'Display' not found"))),
      );
    });

    test('the iPhone tier is a rendering choice, not a re-shoot', () async {
      // The capture is scaled into the frame, so the same raw file serves
      // whichever canvas the config names.
      writeRaw('ko', 'iphone_6_5', '01_home.png', width: 1320, height: 2868);
      await ScreenshotsStep().run(context(config(devices: '[iphone_6_5]')));

      expect(renderer.last.width, 1284);
      expect(renderer.last.height, 2778);
      final out = img.decodePng(File(p.join(tempDir.path, 'fastlane',
              'screenshots', 'ko', 'iphone_6_5_01_home.png'))
          .readAsBytesSync())!;
      expect((out.width, out.height), (1284, 2778));
    });

    test('a placeholder with no value renders empty, never as its token',
        () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      File(assetPath(ScreenshotsStep.templateFileName))
        ..createSync(recursive: true)
        ..writeAsStringSync('<p>{{HEADLINE}}</p><img src="{{IMG}}">');
      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));
      // The literal token must never be baked into a store asset.
      expect(renderer.last.html, contains('<p></p>'));
      expect(renderer.last.html, isNot(contains('HEADLINE')));
      expect(out.toString(), contains('{{HEADLINE}} rendered empty'));
    });

    test('a locale with no copy still renders, reporting every gap',
        () async {
      writeRaw('en-US', 'iphone_6_9', '01_home.png');
      writeDesign('''
screens:
  01_home:
    text:
      ko: { title: 제목, subtitle: 부제 }
''');
      await ScreenshotsStep().run(
          context(config(locales: '[en-US]', devices: '[iphone_6_9]')));
      expect(renderer.last.html, isNot(contains('{{')));
      expect(out.toString(), contains('{{TITLE}}'));
      expect(out.toString(), contains('{{SUBTITLE}}'));
    });

    test('a screen id matching no capture is reported', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      writeDesign('''
screens:
  01_hom: { text: { ko: { title: typo } } }
''');
      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));
      expect(out.toString(), contains('01_hom'));
      expect(out.toString(), contains('match no raw capture'));
    });

    test('missing raw directories warn with the expected path', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      await ScreenshotsStep().run(context(config(locales: '[ko, en-US]')));
      expect(out.toString(), contains('No raw screenshots for en-US'));
    });

    test('fewer than 2 Android screenshots warns (Play minimum)', () async {
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      await ScreenshotsStep().run(context(config(devices: '[android_phone]')));
      expect(out.toString(), contains('at least 2'));
    });

    test('empty locales fail with guidance', () async {
      await expectLater(
        () => ScreenshotsStep().run(context(config(locales: '[]'))),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('screenshots.locales'))),
      );
    });

    test('dry-run previews without writing or rendering', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      await ScreenshotsStep()
          .run(context(config(devices: '[iphone_6_9]'), dryRun: true));
      expect(Directory(p.join(tempDir.path, 'fastlane')).existsSync(), isFalse);
      expect(File(assetPath(ScreenshotsStep.templateFileName)).existsSync(),
          isFalse);
      expect(renderer.calls, isEmpty);
      expect(out.toString(), contains('[dry-run] Would render 1'));
    });
  });

  group('ScreenshotsStep feature graphic', () {
    void writeTwoAndroidRaws() {
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      writeRaw('ko', 'android_phone', '02_stats.png',
          width: 1080, height: 2400);
    }

    File target() => File(p.join(tempDir.path, 'fastlane', 'metadata',
        'android', 'ko', 'images', 'featureGraphic.png'));

    test('is rendered when screenshots.yaml declares it', () async {
      writeTwoAndroidRaws();
      writeDesign('''
screens:
  feature_graphic:
    text:
      ko: { title: 드림로그, subtitle: 꿈을 기록하는 습관 }
''');
      await ScreenshotsStep().run(context(config(devices: '[android_phone]')));

      final graphic =
          renderer.calls.firstWhere((call) => call.width == 1024);
      expect(graphic.height, 500);
      expect(graphic.html, contains('드림로그'));
      final written = img.decodePng(target().readAsBytesSync())!;
      expect((written.width, written.height), (1024, 500));
      // It is not mistaken for a missing screen capture.
      expect(out.toString(), isNot(contains('match no raw capture')));
    });

    test('falls back to a hand-made PNG, and prunes it when removed',
        () async {
      writeTwoAndroidRaws();
      final source = File(
          p.join(tempDir.path, ScreenshotsStep.featureGraphicRelativePath))
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(
            img.Image(width: 1024, height: 500, numChannels: 3)));
      final cfg = config(devices: '[android_phone]');
      await ScreenshotsStep().run(context(cfg));
      expect(target().existsSync(), isTrue);

      source.deleteSync();
      await ScreenshotsStep().run(context(cfg));
      expect(target().existsSync(), isFalse);
    });

    test('a wrong-size hand-made graphic fails with its dimensions',
        () async {
      writeTwoAndroidRaws();
      File(p.join(tempDir.path, ScreenshotsStep.featureGraphicRelativePath))
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(
            img.Image(width: 512, height: 250, numChannels: 3)));
      await expectLater(
        () =>
            ScreenshotsStep().run(context(config(devices: '[android_phone]'))),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('512×250'))),
      );
    });

    test('a hand-made graphic with an alpha channel is rejected', () async {
      writeTwoAndroidRaws();
      File(p.join(tempDir.path, ScreenshotsStep.featureGraphicRelativePath))
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(
            img.Image(width: 1024, height: 500, numChannels: 4)));
      await expectLater(
        () =>
            ScreenshotsStep().run(context(config(devices: '[android_phone]'))),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('alpha'))),
      );
    });
  });

  group('ScreenshotsStep pruning', () {
    test('renamed or removed raw files prune their stale outputs', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      writeRaw('ko', 'iphone_6_9', '02_old.png');
      final cfg = config(devices: '[iphone_6_9]');
      await ScreenshotsStep().run(context(cfg));
      final oldOutput = File(p.join(tempDir.path, 'fastlane', 'screenshots',
          'ko', 'iphone_6_9_02_old.png'));
      expect(oldOutput.existsSync(), isTrue);

      File(p.join(tempDir.path, ScreenshotsStep.rawRelativeDir, 'ko',
              'iphone_6_9', '02_old.png'))
          .deleteSync();
      await ScreenshotsStep().run(context(cfg));
      expect(oldOutput.existsSync(), isFalse);
      expect(
          File(p.join(tempDir.path, 'fastlane', 'screenshots', 'ko',
                  'iphone_6_9_01_home.png'))
              .existsSync(),
          isTrue);
    });

    test('a dropped device prunes its managed files, keeps foreign ones',
        () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      writeRaw('ko', 'ipad_13', '01_home.png');
      await ScreenshotsStep()
          .run(context(config(devices: '[iphone_6_9, ipad_13]')));
      final ipadOutput = File(p.join(tempDir.path, 'fastlane', 'screenshots',
          'ko', 'ipad_13_01_home.png'));
      expect(ipadOutput.existsSync(), isTrue);
      final foreign = File(p.join(
          tempDir.path, 'fastlane', 'screenshots', 'ko', 'framed_custom.png'))
        ..writeAsStringSync('keep me');

      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));
      expect(ipadOutput.existsSync(), isFalse);
      expect(foreign.existsSync(), isTrue);
    });
  });

  group('ScreenshotsDesign', () {
    ScreenshotsDesign parse(String yaml) =>
        ScreenshotsDesign.fromYaml(loadYaml(yaml) as Map, 'screenshots.yaml');

    test('resolves palettes, crops and text with defaults', () {
      final design = parse('''
palettes:
  light: { bg: '#ffffff' }
  night: { bg: '#000000' }
defaults:
  palette: light
  crop_bottom: 40
  text:
    ko: { eyebrow: 드림로그, title: 기본 }
screens:
  01_home:
    palette: night
    crop_bottom: 120
    text:
      ko: { title: 덮어쓴 제목 }
''');
      expect(design.paletteFor('01_home'), {'bg': '#000000'});
      expect(design.paletteFor('02_other'), {'bg': '#ffffff'});
      expect(design.cropBottomFor('01_home'), 120);
      expect(design.cropBottomFor('02_other'), 40);
      expect(design.textFor('01_home', 'ko'),
          {'eyebrow': '드림로그', 'title': '덮어쓴 제목'});
      expect(design.textFor('01_home', 'en-US'), isEmpty);
    });

    test('a missing file parses as an empty design', () {
      final design = ScreenshotsDesign.fromFile(
          p.join(tempDir.path, 'nope.yaml'));
      expect(design.screens, isEmpty);
      expect(design.paletteFor('01_home'), isEmpty);
    });

    test('an undefined palette name fails and lists the defined ones', () {
      expect(
        () => parse('''
palettes: { light: { bg: '#fff' } }
screens: { 01_home: { palette: nite } }
'''),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            allOf(contains("palette 'nite'"), contains('have: light')))),
      );
    });

    test('a palette value that could break out of the CSS is rejected', () {
      expect(
        () => parse("palettes: { x: { bg: 'red; } body { display:none' } }"),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('plain CSS value'))),
      );
    });

    test('a text field shadowing a built-in placeholder is rejected', () {
      for (final field in ['img', 'font_families', 'w']) {
        expect(
          () => parse('screens: { a: { text: { ko: { $field: x } } } }'),
          throwsA(isA<SetupException>().having((e) => e.message, 'message',
              contains('{{${field.toUpperCase()}}}'))),
          reason: field,
        );
      }
    });

    test('a palette key that cannot become a placeholder is rejected', () {
      // {{C_PRIMARY-COLOR}} would never match, so the color would silently
      // vanish from the render.
      expect(
        () => parse("palettes: { x: { primary-color: '#fff' } }"),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            allOf(contains('primary-color'), contains('PLACEHOLDER')))),
      );
    });

    test('a text field posing as a palette colour is rejected', () {
      // Otherwise it would reach the CSS unvalidated, skipping _cssValue.
      expect(
        () => parse("screens: { a: { text: { ko: { c_bg: 'red; }' } } } }"),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('palette'))),
      );
    });

    test('an unknown screen key is rejected', () {
      expect(
        () => parse('screens: { a: { colour: red } }'),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('screens.a.colour'))),
      );
    });

    test('a negative crop is rejected', () {
      expect(
        () => parse('defaults: { crop_bottom: -5 }'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('non-negative'))),
      );
    });
  });

  group('generated defaults', () {
    test('screenshots.yaml parses and defines every colour the templates '
        'ask for', () {
      final design = ScreenshotsDesign.fromYaml(
          loadYaml(ScreenshotTemplates.design('My App')) as Map,
          ScreenshotsStep.designFileName);
      expect(design.defaultPalette, isNotNull);
      final palette = design.palettes[design.defaultPalette]!;

      for (final template in [
        ScreenshotTemplates.screenshot(),
        ScreenshotTemplates.featureGraphic(),
      ]) {
        for (final name in placeholderNames(template).where(
            (n) => n.startsWith(ScreenshotsDesign.palettePlaceholderPrefix))) {
          final key = name
              .substring(ScreenshotsDesign.palettePlaceholderPrefix.length)
              .toLowerCase();
          expect(palette.containsKey(key), isTrue,
              reason: '{{$name}} has no `$key` in the starter palette');
        }
      }
    });
  });

  group('render stamp', () {
    test('survives a PNG encode/decode round-trip', () {
      final image = img.Image(width: 4, height: 4, numChannels: 3);
      image.textData = {ScreenshotsStep.renderStampKeyword: 'abc123'};
      final bytes = Uint8List.fromList(img.encodePng(image));
      expect(pngText(bytes, ScreenshotsStep.renderStampKeyword), 'abc123');
      expect(pngText(bytes, 'other'), isNull);
    });

    test('an unstamped or truncated PNG reads as null', () {
      final bytes = Uint8List.fromList(
          img.encodePng(img.Image(width: 4, height: 4, numChannels: 3)));
      expect(pngText(bytes, ScreenshotsStep.renderStampKeyword), isNull);
      expect(pngText(bytes.sublist(0, 10), 'x'), isNull);
      expect(pngText(Uint8List(0), 'x'), isNull);
    });
  });

  group('config migration', () {
    test("the removed 'captions' key explains where the copy went", () {
      expect(
        () => ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
screenshots:
  locales: [ko]
  captions: assets/store/screenshots/captions.yaml
''') as Map),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            contains('assets/store/screenshots/screenshots.yaml'))),
      );
    });
  });
}
