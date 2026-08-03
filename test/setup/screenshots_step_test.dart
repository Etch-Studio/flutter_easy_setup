import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easy_setup/easy_setup.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Builds a minimal single-glyph ('A') BMFont zip for caption rendering.
List<int> buildTestFontZip() {
  const fnt = '''
info face="test" size=16 bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=1,1 outline=0
common lineHeight=16 base=13 scaleW=16 scaleH=16 pages=1 packed=0 alphaChnl=1 redChnl=0 greenChnl=0 blueChnl=0
page id=0 file="page0.png"
chars count=1
char id=65 x=0 y=0 width=8 height=10 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15
''';
  final page = img.Image(width: 16, height: 16, numChannels: 4);
  img.fill(page, color: img.ColorRgba8(255, 255, 255, 255));
  final pageBytes = img.encodePng(page);
  final archive = Archive()
    ..addFile(ArchiveFile('font.fnt', fnt.length, fnt.codeUnits))
    ..addFile(ArchiveFile('page0.png', pageBytes.length, pageBytes));
  return ZipEncoder().encode(archive);
}

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('screenshots_step_test');
    out = StringBuffer();
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

  ProjectConfig config(
          {String locales = '[ko]',
          String devices = '[iphone_6_9, android_phone]',
          String? captions}) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
screenshots:
  locales: $locales
  devices: $devices
${captions == null ? '' : '  captions: $captions'}
''') as Map);

  SetupContext context(ProjectConfig cfg, {bool dryRun = false}) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg,
        env: const {},
        dryRun: dryRun,
        out: out,
      );

  group('ScreenshotsStep', () {
    test('composes raw captures onto store-spec canvases per platform',
        () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      writeRaw('ko', 'android_phone', '02_stats.png',
          width: 1080, height: 2400);

      await ScreenshotsStep().run(context(config()));

      final ios = File(p.join(tempDir.path, 'fastlane', 'screenshots', 'ko',
          'iphone_6_9_01_home.png'));
      expect(ios.existsSync(), isTrue);
      final iosImage = img.decodePng(ios.readAsBytesSync())!;
      expect((iosImage.width, iosImage.height), (1320, 2868));

      final android = File(p.join(tempDir.path, 'fastlane', 'metadata',
          'android', 'ko', 'images', 'phoneScreenshots', '02_stats.png'));
      expect(android.existsSync(), isTrue);
      final androidImage = img.decodePng(android.readAsBytesSync())!;
      expect((androidImage.width, androidImage.height), (1080, 1920));

      expect(out.toString(), isNot(contains('at least 2')));
    });

    test('is idempotent — second run reports up to date', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      final cfg = config(devices: '[iphone_6_9]');
      await ScreenshotsStep().run(context(cfg));
      out.clear();
      await ScreenshotsStep().run(context(cfg));
      expect(out.toString(), contains('up to date'));
    });

    test('missing raw directories warn with the expected path', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      await ScreenshotsStep().run(context(config(locales: '[ko, en-US]')));
      expect(out.toString(), contains('No raw screenshots for en-US'));
      expect(out.toString(), contains('en-US'));
    });

    test('fewer than 2 Android screenshots warns (Play minimum)', () async {
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      await ScreenshotsStep().run(context(config(devices: '[android_phone]')));
      expect(out.toString(), contains('at least 2'));
    });

    test('captions without a font warn and compose without text', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      File(p.join(tempDir.path, 'captions.yaml')).writeAsStringSync('''
background: '#101528'
screens:
  01_home:
    ko: 꿈을 기록하세요
''');
      await ScreenshotsStep().run(
          context(config(devices: '[iphone_6_9]', captions: captionsPath)));
      expect(out.toString(), contains('captions are skipped'));
      expect(
          File(p.join(tempDir.path, 'fastlane', 'screenshots', 'ko',
                  'iphone_6_9_01_home.png'))
              .existsSync(),
          isTrue);
    });

    test('captions with a BMFont are drawn into the caption zone', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      File(p.join(tempDir.path, 'font.zip'))
          .writeAsBytesSync(buildTestFontZip());
      File(p.join(tempDir.path, 'captions.yaml')).writeAsStringSync('''
background: '#000000'
text_color: '#FF0000'
font: font.zip
screens:
  01_home:
    ko: AAA
''');
      await ScreenshotsStep().run(
          context(config(devices: '[iphone_6_9]', captions: captionsPath)));

      final output = img.decodePng(File(p.join(tempDir.path, 'fastlane',
              'screenshots', 'ko', 'iphone_6_9_01_home.png'))
          .readAsBytesSync())!;
      // Some pixel in the caption zone (top 16%) carries the text color.
      var found = false;
      for (var y = 0; y < (2868 * 0.16).round() && !found; y++) {
        for (var x = 0; x < 1320 && !found; x++) {
          final pixel = output.getPixel(x, y);
          if (pixel.r > 200 && pixel.g < 50 && pixel.b < 50) found = true;
        }
      }
      expect(found, isTrue,
          reason: 'expected red caption pixels in the top zone');
      expect(out.toString(), isNot(contains('captions are skipped')));
    });

    test('a declared but missing font fails with guidance', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      File(p.join(tempDir.path, 'captions.yaml')).writeAsStringSync('''
font: nope.zip
screens:
  01_home: { ko: Hi }
''');
      await expectLater(
        () => ScreenshotsStep().run(
            context(config(devices: '[iphone_6_9]', captions: captionsPath))),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('Caption font not found'))),
      );
    });

    test('feature graphic is validated and copied per locale', () async {
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      writeRaw('ko', 'android_phone', '02_stats.png',
          width: 1080, height: 2400);
      final graphic = img.Image(width: 1024, height: 500, numChannels: 3);
      File(p.join(tempDir.path, ScreenshotsStep.featureGraphicRelativePath))
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(graphic));

      await ScreenshotsStep().run(context(config(devices: '[android_phone]')));
      expect(
          File(p.join(tempDir.path, 'fastlane', 'metadata', 'android', 'ko',
                  'images', 'featureGraphic.png'))
              .existsSync(),
          isTrue);
    });

    test('a wrong-size feature graphic fails with its dimensions', () async {
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      writeRaw('ko', 'android_phone', '02_stats.png',
          width: 1080, height: 2400);
      final graphic = img.Image(width: 512, height: 250, numChannels: 3);
      File(p.join(tempDir.path, ScreenshotsStep.featureGraphicRelativePath))
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(graphic));
      await expectLater(
        () => ScreenshotsStep().run(context(config(devices: '[android_phone]'))),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('512×250'))),
      );
    });

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
      // The surviving screenshot stays.
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
      // A file easy_setup does not manage survives pruning.
      final foreign = File(p.join(
          tempDir.path, 'fastlane', 'screenshots', 'ko', 'framed_custom.png'))
        ..writeAsStringSync('keep me');

      await ScreenshotsStep().run(context(config(devices: '[iphone_6_9]')));
      expect(ipadOutput.existsSync(), isFalse);
      expect(foreign.existsSync(), isTrue);
    });

    test('a removed feature graphic source removes the copied target',
        () async {
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      writeRaw('ko', 'android_phone', '02_stats.png',
          width: 1080, height: 2400);
      final source = File(
          p.join(tempDir.path, ScreenshotsStep.featureGraphicRelativePath))
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(
            img.Image(width: 1024, height: 500, numChannels: 3)));
      final cfg = config(devices: '[android_phone]');
      await ScreenshotsStep().run(context(cfg));
      final target = File(p.join(tempDir.path, 'fastlane', 'metadata',
          'android', 'ko', 'images', 'featureGraphic.png'));
      expect(target.existsSync(), isTrue);

      source.deleteSync();
      await ScreenshotsStep().run(context(cfg));
      expect(target.existsSync(), isFalse);
    });

    test('a feature graphic with an alpha channel is rejected', () async {
      writeRaw('ko', 'android_phone', '01_home.png',
          width: 1080, height: 2400);
      writeRaw('ko', 'android_phone', '02_stats.png',
          width: 1080, height: 2400);
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

    test('an over-wide caption warns about clipping', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      File(p.join(tempDir.path, 'font.zip'))
          .writeAsBytesSync(buildTestFontZip());
      // 150 glyphs × 8px advance = 1200px > the 1162px usable width.
      File(p.join(tempDir.path, 'captions.yaml')).writeAsStringSync('''
font: font.zip
screens:
  01_home:
    ko: ${'A' * 150}
''');
      await ScreenshotsStep().run(
          context(config(devices: '[iphone_6_9]', captions: captionsPath)));
      expect(out.toString(), contains('clipped'));
    });

    test('empty locales fail with guidance', () async {
      await expectLater(
        () => ScreenshotsStep().run(context(config(locales: '[]'))),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('screenshots.locales'))),
      );
    });

    test('dry-run previews without writing', () async {
      writeRaw('ko', 'iphone_6_9', '01_home.png');
      await ScreenshotsStep()
          .run(context(config(devices: '[iphone_6_9]'), dryRun: true));
      expect(
          Directory(p.join(tempDir.path, 'fastlane')).existsSync(), isFalse);
      expect(out.toString(), contains('[dry-run] Would compose 1'));
    });
  });

  group('CaptionsConfig', () {
    test('parses colors, font, and screens', () {
      final config = CaptionsConfig.fromYaml(
          loadYaml('''
background: '#101528'
text_color: '#EEEEEE'
font: assets/font.zip
screens:
  01_home:
    ko: 안녕
    en-US: Hello
''') as Map,
          'captions.yaml');
      expect(config.background, '#101528');
      expect(config.textColor, '#EEEEEE');
      expect(config.fontPath, 'assets/font.zip');
      expect(config.screens['01_home']!['en-US'], 'Hello');
    });

    test('rejects a malformed color', () {
      expect(
        () => CaptionsConfig.fromYaml(
            loadYaml("background: 'blue'") as Map, 'captions.yaml'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('#RRGGBB'))),
      );
    });
  });
}

const captionsPath = 'captions.yaml';
