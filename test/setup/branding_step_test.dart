import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tempDir;
  late StringBuffer out;
  late String srcDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('branding_step_test');
    out = StringBuffer();
    srcDir = p.join(tempDir.path, 'assets', 'branding', 'icon');
    Directory(srcDir).createSync(recursive: true);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  void writePng(String name,
      {int size = 1024, bool alphaChannel = false, bool transparentCorner = false}) {
    final image = img.Image(
        width: size, height: size, numChannels: alphaChannel ? 4 : 3);
    img.fill(image, color: img.ColorRgba8(30, 90, 200, 255));
    if (transparentCorner) {
      image.setPixelRgba(0, 0, 0, 0, 0, 128);
    }
    File(p.join(srcDir, name)).writeAsBytesSync(img.encodePng(image));
  }

  /// fg.png whose opaque content stays inside the central 66% safe area.
  void writeSafeFg() {
    final image = img.Image(width: 1024, height: 1024, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
    img.fillRect(image,
        x1: 400, y1: 400, x2: 620, y2: 620,
        color: img.ColorRgba8(255, 255, 255, 255));
    File(p.join(srcDir, 'fg.png')).writeAsBytesSync(img.encodePng(image));
  }

  ProjectConfig config() => ProjectConfig.fromYaml(loadYaml('''
app: { name: X, bundle_id: com.x }
branding: { icon_src: assets/branding/icon/ }
''') as Map);

  SetupContext context({bool dryRun = false}) => SetupContext(
        projectRoot: tempDir.path,
        config: config(),
        env: const {},
        dryRun: dryRun,
        out: out,
      );

  group('BrandingStep', () {
    test('generates iOS appiconset and Android legacy mipmaps', () async {
      writePng('icon.png');
      await BrandingStep().run(context());

      final appiconset = Directory(p.join(
          ProjectFinder.iosAssetCatalogDir(tempDir.path),
          'AppIcon.appiconset'));
      expect(appiconset.existsSync(), isTrue);
      final files = appiconset.listSync().map((e) => p.basename(e.path));
      expect(files, contains('Contents.json'));
      expect(files.where((f) => f.endsWith('.png')), hasLength(15));

      final resDir = ProjectFinder.androidResDir(tempDir.path);
      for (final entry in BrandingStep.launcherSizes.entries) {
        final file =
            File(p.join(resDir, 'mipmap-${entry.key}', 'ic_launcher.png'));
        expect(file.existsSync(), isTrue, reason: entry.key);
        final decoded = img.decodePng(file.readAsBytesSync())!;
        expect(decoded.width, entry.value);
      }
      // No adaptive sources → no adaptive outputs.
      expect(
          File(p.join(resDir, 'mipmap-anydpi-v26', 'ic_launcher.xml'))
              .existsSync(),
          isFalse);
    });

    test('generates adaptive layers + themed monochrome when sources exist',
        () async {
      writePng('icon.png');
      writeSafeFg();
      writePng('bg.png');
      writePng('mono.png', alphaChannel: true);
      await BrandingStep().run(context());

      final resDir = ProjectFinder.androidResDir(tempDir.path);
      for (final entry in BrandingStep.adaptiveSizes.entries) {
        final dir = p.join(resDir, 'mipmap-${entry.key}');
        for (final layer in [
          'ic_launcher_foreground.png',
          'ic_launcher_background.png',
          'ic_launcher_monochrome.png',
        ]) {
          final file = File(p.join(dir, layer));
          expect(file.existsSync(), isTrue, reason: '$dir/$layer');
          expect(img.decodePng(file.readAsBytesSync())!.width, entry.value);
        }
      }
      final xml = File(p.join(resDir, 'mipmap-anydpi-v26', 'ic_launcher.xml'))
          .readAsStringSync();
      expect(xml, contains('ic_launcher_foreground'));
      expect(xml, contains('ic_launcher_monochrome'));
      // No safe-area warning for content inside the central 66%.
      expect(out.toString(), isNot(contains('safe area')));
    });

    test('is idempotent — second run reports up to date', () async {
      writePng('icon.png');
      writeSafeFg();
      writePng('bg.png');
      await BrandingStep().run(context());
      out.clear();
      await BrandingStep().run(context());
      expect(out.toString(), contains('ic_launcher.png up to date'));
      expect(out.toString(), contains('adaptive icons up to date'));
    });

    test('rejects an icon with transparency (App Store rule)', () async {
      writePng('icon.png', alphaChannel: true, transparentCorner: true);
      await expectLater(
        () => BrandingStep().run(context()),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('transparent'))),
      );
    });

    test('a fully opaque 4-channel icon is accepted and flattened to RGB',
        () async {
      writePng('icon.png', alphaChannel: true);
      await BrandingStep().run(context());
      expect(out.toString(), contains('AppIcon.appiconset'));
      // App Store validation rejects any alpha channel — outputs are RGB.
      final marketing = File(p.join(
          ProjectFinder.iosAssetCatalogDir(tempDir.path),
          'AppIcon.appiconset',
          'Icon-App-1024x1024@1x.png'));
      expect(img.decodePng(marketing.readAsBytesSync())!.numChannels, 3);
    });

    test('unchanged iOS icons are not rewritten on a second run', () async {
      writePng('icon.png');
      await BrandingStep().run(context());
      final marketing = File(p.join(
          ProjectFinder.iosAssetCatalogDir(tempDir.path),
          'AppIcon.appiconset',
          'Icon-App-1024x1024@1x.png'));
      final before = marketing.lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await BrandingStep().run(context());
      expect(marketing.lastModifiedSync(), before);
    });

    test('removed adaptive sources remove the stale outputs', () async {
      writePng('icon.png');
      writeSafeFg();
      writePng('bg.png');
      writePng('mono.png', alphaChannel: true);
      await BrandingStep().run(context());
      final resDir = ProjectFinder.androidResDir(tempDir.path);
      final xml =
          File(p.join(resDir, 'mipmap-anydpi-v26', 'ic_launcher.xml'));
      expect(xml.existsSync(), isTrue);

      // Drop mono only → monochrome layers disappear, adaptive stays.
      File(p.join(srcDir, 'mono.png')).deleteSync();
      await BrandingStep().run(context());
      expect(
          File(p.join(resDir, 'mipmap-mdpi', 'ic_launcher_monochrome.png'))
              .existsSync(),
          isFalse);
      expect(xml.existsSync(), isTrue);
      expect(xml.readAsStringSync(), isNot(contains('monochrome')));

      // Drop fg/bg → all adaptive outputs disappear.
      File(p.join(srcDir, 'fg.png')).deleteSync();
      File(p.join(srcDir, 'bg.png')).deleteSync();
      await BrandingStep().run(context());
      expect(xml.existsSync(), isFalse);
      expect(
          File(p.join(resDir, 'mipmap-xxxhdpi', 'ic_launcher_foreground.png'))
              .existsSync(),
          isFalse);
    });

    test('rejects a wrong-size source', () async {
      writePng('icon.png', size: 512);
      await expectLater(
        () => BrandingStep().run(context()),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('1024'))),
      );
    });

    test('warns when fg content leaves the 66% safe area', () async {
      writePng('icon.png');
      // Opaque pixels across the whole square → outside the safe area.
      writePng('fg.png', alphaChannel: true);
      writePng('bg.png');
      await BrandingStep().run(context());
      expect(out.toString(), contains('safe area'));
    });

    test('missing icon.png fails with guidance', () async {
      await expectLater(
        () => BrandingStep().run(context()),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('icon.png'))),
      );
    });

    test('fg without bg warns and skips adaptive icons', () async {
      writePng('icon.png');
      writeSafeFg();
      await BrandingStep().run(context());
      expect(out.toString(), contains('BOTH fg.png and bg.png'));
      expect(
          File(p.join(ProjectFinder.androidResDir(tempDir.path),
                  'mipmap-anydpi-v26', 'ic_launcher.xml'))
              .existsSync(),
          isFalse);
    });

    test('dry-run touches nothing', () async {
      writePng('icon.png');
      writeSafeFg();
      writePng('bg.png');
      await BrandingStep().run(context(dryRun: true));
      expect(Directory(p.join(tempDir.path, 'ios')).existsSync(), isFalse);
      expect(Directory(p.join(tempDir.path, 'android')).existsSync(), isFalse);
      expect(out.toString(), contains('[dry-run]'));
    });
  });
}
