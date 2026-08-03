import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';
import '../utils/idempotent_writer.dart';
import 'captions_config.dart';
import 'setup_step.dart';

/// Screenshot composition layer (V2_PLAN.md §5.2, layer ②): turns raw
/// captures into store-ready marketing screenshots.
///
/// Inputs (git-versioned):
/// - `assets/store/screenshots/raw/{locale}/{device}/*.png` — raw captures
///   (layer ① — captured via integration_test or by hand)
/// - `screenshots.captions` → captions.yaml (colors, per-locale captions,
///   optional BMFont zip for text rendering)
/// - `assets/store/screenshots/feature_graphic.png` — optional, 1024×500
///
/// Outputs (what fastlane deliver/supply upload):
/// - iOS: `fastlane/screenshots/{locale}/{device}_{name}.png`
///   (iPhone 6.9" 1320×2868 + iPad 13" 2064×2752 — the two sizes Apple
///   auto-scales everything else from)
/// - Android: `fastlane/metadata/android/{locale}/images/phoneScreenshots/`
///   (1080×1920) + `images/featureGraphic.png`
class ScreenshotsStep extends SetupStep {
  static const rawRelativeDir = 'assets/store/screenshots/raw';
  static const featureGraphicRelativePath =
      'assets/store/screenshots/feature_graphic.png';

  /// Store canvas sizes per supported device key.
  static const deviceSpecs = {
    'iphone_6_9': (width: 1320, height: 2868, ios: true),
    'ipad_13': (width: 2064, height: 2752, ios: true),
    'android_phone': (width: 1080, height: 1920, ios: false),
  };

  @override
  String get name => 'screenshots';

  @override
  bool isConfigured(ProjectConfig config) => config.screenshots != null;

  @override
  Future<void> run(SetupContext context) async {
    final shots = context.config.screenshots!;
    if (shots.locales.isEmpty) {
      throw SetupException(
        "Screenshot composition needs 'screenshots.locales' in "
        'easy_setup.yaml (e.g. [ko, en-US]).',
      );
    }
    final devices = shots.devices.isEmpty
        ? ScreenshotsConfig.allowedDevices
        : shots.devices;

    final captions = shots.captions == null
        ? null
        : CaptionsConfig.fromFile(
            p.join(context.projectRoot, shots.captions));
    final font = _loadFont(context, captions);
    if (captions != null && captions.screens.isNotEmpty && font == null) {
      context.out.writeln(
          '  ! Captions are declared but no font is configured — captions '
          "are skipped. Add 'font: <path>.zip' to captions.yaml (BMFont "
          'format, e.g. generated from a TTF; required for non-Latin text).');
    }

    var composed = 0;
    var changed = 0;
    for (final locale in shots.locales) {
      // Track what this run owns so stale outputs can be pruned — fastlane
      // uploads whatever sits in these directories.
      final expectedIos = <String>{};
      final expectedAndroid = <String>{};
      for (final device in devices) {
        final spec = deviceSpecs[device]!;
        final rawDir = Directory(
            p.join(context.projectRoot, rawRelativeDir, locale, device));
        if (!rawDir.existsSync()) {
          context.out.writeln(
              '  ! No raw screenshots for $locale/$device — expected '
              '${rawDir.path}');
          continue;
        }
        final rawFiles = rawDir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.png'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        if (rawFiles.isEmpty) {
          context.out
              .writeln('  ! ${rawDir.path} contains no .png files');
          continue;
        }
        if (!spec.ios && rawFiles.length < 2) {
          context.out.writeln(
              '  ! Google Play needs at least 2 phone screenshots — '
              '$locale/$device has ${rawFiles.length}');
        }

        if (context.dryRun) {
          for (final rawFile in rawFiles) {
            (spec.ios ? expectedIos : expectedAndroid).add(_outputPath(
                context.projectRoot, locale, device, spec.ios,
                p.basename(rawFile.path)));
          }
          context.out.writeln(
              '  [dry-run] Would compose ${rawFiles.length} screenshot(s) '
              'for $locale/$device '
              '(${spec.width}×${spec.height})');
          composed += rawFiles.length;
          continue;
        }

        for (final rawFile in rawFiles) {
          final raw = img.decodePng(rawFile.readAsBytesSync());
          if (raw == null) {
            throw SetupException('Failed to decode PNG: ${rawFile.path}');
          }
          final screen = p.basenameWithoutExtension(rawFile.path);
          final caption = captions?.screens[screen]?[locale];
          final canvas = _compose(
            raw: raw,
            width: spec.width,
            height: spec.height,
            caption: font == null ? null : caption,
            font: font,
            background: captions?.background ?? '#000000',
            textColor: captions?.textColor ?? '#FFFFFF',
            onWarn: (message) =>
                context.out.writeln('  ! $locale/$screen: $message'),
          );
          final outFile = File(_outputPath(
              context.projectRoot, locale, device, spec.ios,
              p.basename(rawFile.path)));
          (spec.ios ? expectedIos : expectedAndroid).add(outFile.path);
          changed += writeBytesIfChanged(outFile, img.encodePng(canvas));
          composed++;
        }
        context.out.writeln(
            '  ✓ $locale/$device: ${rawFiles.length} screenshot(s) '
            '(${spec.width}×${spec.height})');
      }

      final managesAndroid =
          devices.any((device) => !deviceSpecs[device]!.ios);
      if (managesAndroid) {
        changed += _copyFeatureGraphic(context, locale);
      }
      changed += _prune(context, locale, expectedIos, expectedAndroid,
          managesAndroid: managesAndroid);
    }

    if (composed == 0) {
      context.out.writeln(
          '  ! Nothing composed — put raw captures under '
          '$rawRelativeDir/{locale}/{device}/.');
    } else if (!context.dryRun) {
      context.out.writeln(changed > 0
          ? '  ✓ Store screenshots written to fastlane/ '
              '($changed file(s) updated)'
          : '  ✓ Store screenshots up to date');
      if (devices.any((device) => deviceSpecs[device]!.ios)) {
        context.out.writeln(
            '  → Android assets upload on the next `easy_setup deploy`; '
            'the iOS App Store upload (deliver) is not wired into deploy '
            'yet — upload fastlane/screenshots/ via `fastlane deliver` or '
            'App Store Connect for now.');
      }
    }
  }

  String _outputPath(String root, String locale, String device, bool ios,
          String fileName) =>
      ios
          ? p.join(root, 'fastlane', 'screenshots', locale,
              '${device}_$fileName')
          : p.join(root, 'fastlane', 'metadata', 'android', locale, 'images',
              'phoneScreenshots', fileName);

  /// Removes managed outputs this run no longer produces — a renamed raw
  /// file or a dropped device must not leave stale store assets behind.
  /// iOS files are managed by their device-key prefix; the Android
  /// phoneScreenshots directory (and featureGraphic) are managed wholly.
  int _prune(SetupContext context, String locale, Set<String> expectedIos,
      Set<String> expectedAndroid,
      {required bool managesAndroid}) {
    final stale = <File>[];

    final iosDir = Directory(
        p.join(context.projectRoot, 'fastlane', 'screenshots', locale));
    if (iosDir.existsSync()) {
      for (final file in iosDir.listSync().whereType<File>()) {
        final name = p.basename(file.path);
        final managed =
            deviceSpecs.keys.any((device) => name.startsWith('${device}_'));
        if (managed && !expectedIos.contains(file.path)) stale.add(file);
      }
    }

    if (managesAndroid) {
      final androidDir = Directory(p.join(context.projectRoot, 'fastlane',
          'metadata', 'android', locale, 'images', 'phoneScreenshots'));
      if (androidDir.existsSync()) {
        for (final file in androidDir.listSync().whereType<File>()) {
          if (!expectedAndroid.contains(file.path)) stale.add(file);
        }
      }
      final graphicSource =
          File(p.join(context.projectRoot, featureGraphicRelativePath));
      final graphicTarget = File(p.join(context.projectRoot, 'fastlane',
          'metadata', 'android', locale, 'images', 'featureGraphic.png'));
      if (!graphicSource.existsSync() && graphicTarget.existsSync()) {
        stale.add(graphicTarget);
      }
    }

    if (stale.isEmpty) return 0;
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would remove ${stale.length} stale output(s) for '
          '$locale');
      return 0;
    }
    for (final file in stale) {
      file.deleteSync();
    }
    context.out
        .writeln('  ✓ Removed ${stale.length} stale output(s) for $locale');
    return stale.length;
  }

  img.BitmapFont? _loadFont(SetupContext context, CaptionsConfig? captions) {
    final fontPath = captions?.fontPath;
    if (fontPath == null) return null;
    final file = File(p.join(context.projectRoot, fontPath));
    if (!file.existsSync()) {
      throw SetupException(
        'Caption font not found: ${file.path} (captions.yaml `font`).',
      );
    }
    try {
      return img.BitmapFont.fromZip(file.readAsBytesSync());
    } catch (e) {
      throw SetupException(
          'Could not load the BMFont zip at ${file.path}: $e');
    }
  }

  /// Draws the store canvas: background color, optional caption on top,
  /// raw screenshot contain-fitted below.
  img.Image _compose({
    required img.Image raw,
    required int width,
    required int height,
    required String? caption,
    required img.BitmapFont? font,
    required String background,
    required String textColor,
    required void Function(String) onWarn,
  }) {
    final canvas = img.Image(width: width, height: height, numChannels: 3);
    img.fill(canvas, color: _color(background));

    final hasCaption = caption != null && caption.isNotEmpty && font != null;
    final captionZone = hasCaption ? (height * 0.16).round() : 0;
    final sideMargin = (width * 0.06).round();
    final verticalMargin = (height * 0.04).round();

    final availableWidth = width - 2 * sideMargin;
    final availableHeight = height - captionZone - 2 * verticalMargin;
    final scale = math.min(
        availableWidth / raw.width, availableHeight / raw.height);
    final targetWidth = (raw.width * scale).round();
    final targetHeight = (raw.height * scale).round();
    final resized = img.copyResize(
      raw,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.average,
    );
    img.compositeImage(
      canvas,
      resized,
      dstX: (width - targetWidth) ~/ 2,
      dstY: captionZone +
          verticalMargin +
          (availableHeight - targetHeight) ~/ 2,
    );

    if (hasCaption) {
      final textWidth = _measure(font, caption);
      if (textWidth > availableWidth) {
        onWarn('caption is wider than the canvas '
            '(${textWidth}px > ${availableWidth}px) and will be clipped — '
            'shorten it or use a smaller font.');
      }
      img.drawString(
        canvas,
        caption,
        font: font,
        x: math.max(0, (width - textWidth) ~/ 2),
        y: math.max(0, (captionZone - font.lineHeight) ~/ 2),
        color: _color(textColor),
      );
    }
    return canvas;
  }

  int _measure(img.BitmapFont font, String text) {
    var width = 0;
    for (final rune in text.runes) {
      width += font.characters[rune]?.xAdvance ?? font.base ~/ 2;
    }
    return width;
  }

  /// Validates and copies the feature graphic for one locale. Returns the
  /// number of changed files.
  int _copyFeatureGraphic(SetupContext context, String locale) {
    final source =
        File(p.join(context.projectRoot, featureGraphicRelativePath));
    if (!source.existsSync()) return 0;
    final image = img.decodePng(source.readAsBytesSync());
    if (image == null || image.width != 1024 || image.height != 500) {
      throw SetupException(
        '$featureGraphicRelativePath must be a 1024×500 PNG '
        '(got ${image == null ? 'undecodable' : '${image.width}×${image.height}'}).',
      );
    }
    if (image.numChannels == 4) {
      throw SetupException(
        '$featureGraphicRelativePath must be a 24-bit PNG without an alpha '
        'channel (Google Play requirement) — flatten it onto a solid '
        'background.',
      );
    }
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would copy the feature graphic for $locale');
      return 0;
    }
    final target = File(p.join(context.projectRoot, 'fastlane', 'metadata',
        'android', locale, 'images', 'featureGraphic.png'));
    return writeBytesIfChanged(target, source.readAsBytesSync());
  }

  img.Color _color(String hex) => img.ColorRgb8(
        int.parse(hex.substring(1, 3), radix: 16),
        int.parse(hex.substring(3, 5), radix: 16),
        int.parse(hex.substring(5, 7), radix: 16),
      );
}
