import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';
import '../render/template_fill.dart';
import '../utils/content_hash.dart';
import '../utils/idempotent_writer.dart';
import '../utils/project_finder.dart';
import 'screenshot_templates.dart';
import 'screenshots_design.dart';
import 'setup_step.dart';

/// Screenshot composition layer (V2_PLAN.md §5.2, layer ②): turns raw
/// captures into store-ready marketing screenshots.
///
/// The design is an HTML page rendered by headless Chrome at the exact
/// store canvas size — text sources that live in git, that an AI skill can
/// rewrite, and that re-render identically on any machine.
///
/// Inputs (git-versioned, under `assets/store/screenshots/`):
/// - `raw/{locale}/{device}/*.png` — raw captures (layer ①, captured by
///   hand or by an integration test)
/// - `screenshots.yaml` — per-screen copy, palettes, fonts, cropping
/// - `template.html` — the frame design
/// - `feature_graphic.html` — optional Play feature graphic design
///
/// Outputs (what fastlane deliver/supply upload):
/// - iOS: `fastlane/screenshots/{locale}/{device}_{name}.png`
///   (iPhone 6.9" 1320×2868 + iPad 13" 2064×2752 — the two sizes Apple
///   auto-scales everything else from)
/// - Android: `fastlane/metadata/android/{locale}/images/phoneScreenshots/`
///   (1080×1920) + `images/featureGraphic.png` (1024×500)
class ScreenshotsStep extends SetupStep {
  static const assetsRelativeDir = 'assets/store/screenshots';
  static const rawRelativeDir = '$assetsRelativeDir/raw';
  static const designFileName = 'screenshots.yaml';
  static const templateFileName = 'template.html';
  static const featureGraphicTemplateName = 'feature_graphic.html';
  static const featureGraphicRelativePath =
      '$assetsRelativeDir/feature_graphic.png';
  static const skillRelativePath = '.claude/skills/store-screenshots/SKILL.md';

  /// Screen id whose copy drives the Play feature graphic. Its presence in
  /// screenshots.yaml is what opts the project into rendering one.
  static const featureGraphicScreen = 'feature_graphic';
  static const featureGraphicWidth = 1024;
  static const featureGraphicHeight = 500;

  /// PNG tEXt keyword holding the fingerprint of the inputs that produced
  /// the file, so an unchanged screen can skip a browser round-trip.
  static const renderStampKeyword = 'easy_setup_render';

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

    _scaffold(context, devices);

    final assetsDir = p.join(context.projectRoot, assetsRelativeDir);
    final design =
        ScreenshotsDesign.fromFile(p.join(assetsDir, designFileName));
    // A dry run previews the plan; it neither renders nor needs the design
    // sources it would have scaffolded.
    final template =
        context.dryRun ? '' : _readTemplate(assetsDir, templateFileName);
    final fontCss = context.dryRun ? '' : _fontCss(context, design);
    final fontFamilies =
        design.fonts.keys.map((family) => "'$family',").join(' ');
    final unresolved = <String>{};

    var composed = 0;
    var rendered = 0;
    var changed = 0;
    final seenScreens = <String>{};

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
          context.out.writeln('  ! ${rawDir.path} contains no .png files');
          continue;
        }
        if (!spec.ios && rawFiles.length < 2) {
          context.out.writeln(
              '  ! Google Play needs at least 2 phone screenshots — '
              '$locale/$device has ${rawFiles.length}');
        }

        for (final (index, rawFile) in rawFiles.indexed) {
          final screen = p.basenameWithoutExtension(rawFile.path);
          seenScreens.add(screen);
          final outFile = File(_outputPath(context.projectRoot, locale, device,
              spec.ios, p.basename(rawFile.path)));
          (spec.ios ? expectedIos : expectedAndroid).add(outFile.path);
          composed++;

          if (context.dryRun) continue;

          final html = _fill(template, {
            // User values first: a built-in must never be shadowed, and
            // the parser already rejects the names that could collide.
            ..._placeholders(
                design.textFor(screen, locale), design.paletteFor(screen)),
            'W': '${spec.width}',
            'H': '${spec.height}',
            'IMG': _dataUri(
                _crop(context, rawFile, design.cropBottomFor(screen))),
            'SCREEN_AR': '1/1',
            'FONT_CSS': fontCss,
            'FONT_FAMILIES': fontFamilies,
            'INDEX': '${index + 1}',
            'COUNT': '${rawFiles.length}',
            'LOCALE': locale,
            'DEVICE': device,
            'SCREEN': screen,
          }, unresolved);

          final result = await _renderTo(
            context,
            outFile,
            html: html,
            width: spec.width,
            height: spec.height,
          );
          if (result.$1) rendered++;
          changed += result.$2;
        }
        if (!context.dryRun) {
          context.out.writeln(
              '  ✓ $locale/$device: ${rawFiles.length} screenshot(s) '
              '(${spec.width}×${spec.height})');
        }
      }

      final managesAndroid =
          devices.any((device) => !deviceSpecs[device]!.ios);
      var producedGraphic = false;
      if (managesAndroid) {
        final graphic = await _featureGraphic(context, locale, design,
            fontCss: fontCss,
            fontFamilies: fontFamilies,
            unresolved: unresolved);
        producedGraphic = graphic.$1;
        changed += graphic.$2;
      }
      changed += _prune(context, locale, expectedIos, expectedAndroid,
          managesAndroid: managesAndroid, keepFeatureGraphic: producedGraphic);
    }

    _report(context, design,
        composed: composed,
        rendered: rendered,
        changed: changed,
        seenScreens: seenScreens,
        unresolved: unresolved,
        devices: devices);
  }

  // --- Scaffolding ---------------------------------------------------------

  /// Seeds the design sources and the AI skill on first run. All of them
  /// are user-owned afterwards, so they are only ever created.
  void _scaffold(SetupContext context, List<String> devices) {
    final assetsDir = p.join(context.projectRoot, assetsRelativeDir);
    if (context.dryRun) {
      if (!File(p.join(assetsDir, templateFileName)).existsSync()) {
        context.out.writeln(
            '  [dry-run] Would create $assetsRelativeDir/$templateFileName, '
            '$designFileName, $featureGraphicTemplateName and the '
            'store-screenshots Claude skill');
      }
      return;
    }
    var changed = 0;
    changed += writeIfAbsent(File(p.join(assetsDir, templateFileName)),
        ScreenshotTemplates.screenshot());
    changed += writeIfAbsent(
        File(p.join(assetsDir, featureGraphicTemplateName)),
        ScreenshotTemplates.featureGraphic());
    changed += writeIfAbsent(File(p.join(assetsDir, designFileName)),
        ScreenshotTemplates.design(context.config.app.name));

    final gitRoot =
        ProjectFinder.findGitRoot(context.projectRoot) ?? context.projectRoot;
    changed += writeIfAbsent(
      File(p.join(gitRoot, skillRelativePath)),
      ScreenshotTemplates.skill(
        projectRoot: p.relative(context.projectRoot, from: gitRoot),
        assetsDir: assetsRelativeDir,
        bundleId: context.config.app.bundleId,
        devices: devices,
      ),
    );
    if (changed > 0) {
      context.out.writeln(
          '  ✓ Created $changed design source(s) — edit '
          '$assetsRelativeDir/$designFileName and $templateFileName, or ask '
          'Claude: "/store-screenshots"');
    }
  }

  String _readTemplate(String assetsDir, String fileName) {
    final file = File(p.join(assetsDir, fileName));
    if (!file.existsSync()) {
      throw SetupException(
        '${file.path} not found — it is generated on the first '
        '`easy_setup setup --only screenshots`; restore it from git or '
        'delete it and re-run to regenerate the default.',
      );
    }
    return file.readAsStringSync();
  }

  // --- Rendering -----------------------------------------------------------

  /// Renders [html] into [outFile] unless the file already carries this
  /// input's fingerprint. Returns (did render, files changed).
  Future<(bool, int)> _renderTo(
    SetupContext context,
    File outFile, {
    required String html,
    required int width,
    required int height,
  }) async {
    final stamp = contentHash([html, '$width', '$height']);
    if (outFile.existsSync() &&
        pngText(outFile.readAsBytesSync(), renderStampKeyword) == stamp) {
      return (false, 0);
    }
    final image = await context.renderer
        .render(html: html, width: width, height: height);
    // Stores reject assets with an alpha channel even when fully opaque.
    final flattened =
        image.numChannels == 4 ? image.convert(numChannels: 3) : image;
    flattened.textData = {renderStampKeyword: stamp};
    return (true, writeBytesIfChanged(outFile, img.encodePng(flattened)));
  }

  /// Loads a raw capture and trims [cropBottom] pixels off its bottom
  /// (ad banners, home indicators).
  img.Image _crop(SetupContext context, File rawFile, int cropBottom) {
    final raw = img.decodePng(rawFile.readAsBytesSync());
    if (raw == null) {
      throw SetupException('Failed to decode PNG: ${rawFile.path}');
    }
    if (cropBottom <= 0) return raw;
    if (cropBottom >= raw.height) {
      throw SetupException(
        'crop_bottom ($cropBottom) removes the whole '
        '${raw.width}×${raw.height} capture ${p.basename(rawFile.path)}.',
      );
    }
    return img.copyCrop(raw,
        x: 0, y: 0, width: raw.width, height: raw.height - cropBottom);
  }

  /// Fills [template] and blanks every placeholder that has no value,
  /// recording the names in [unresolved].
  ///
  /// Blanking rather than leaving the token in place is what makes an
  /// optional line (a screen with no subtitle) work: the templates hide
  /// empty elements. A literal `{{SUBTITLE}}` baked into a store asset —
  /// and then fingerprinted as up to date — would be far worse.
  String _fill(String template, Map<String, String> values,
      Set<String> unresolved) {
    // Scanned on the template, not on the filled output: copy that
    // contains `{{...}}` is the author's literal text, not a placeholder.
    final missing = placeholderNames(template)
        .where((name) => !values.containsKey(name))
        .toList();
    unresolved.addAll(missing);
    return fillTemplate(template, {
      ...values,
      for (final name in missing) name: '',
    });
  }

  /// Text fields become `{{TITLE}}`-style placeholders, palette entries
  /// `{{C_BG}}`-style ones — the `C_` prefix keeps a color named `title`
  /// from colliding with the headline.
  Map<String, String> _placeholders(
          Map<String, String> text, Map<String, String> palette) =>
      {
        for (final entry in text.entries)
          entry.key.toUpperCase(): _copy(entry.value),
        for (final entry in palette.entries)
          '${ScreenshotsDesign.palettePlaceholderPrefix}'
                  '${entry.key.toUpperCase()}':
              entry.value,
      };

  /// Prepares one piece of store copy for the page.
  ///
  /// It is text, not markup: `&` and `<` in a headline must survive as
  /// themselves rather than silently rewriting the DOM. A newline becomes
  /// a line break, so `title: "two\nlines"` does what it looks like — HTML
  /// would otherwise collapse it to a space.
  static String _copy(String value) => htmlEscape
      .convert(value.replaceAll('\r\n', '\n'))
      .replaceAll('\n', '<br>');

  String _dataUri(img.Image image) =>
      'data:image/png;base64,${base64Encode(img.encodePng(image))}';

  /// Embeds the declared fonts as `@font-face` data URIs — the render has
  /// no network, and bundling keeps the output identical everywhere.
  String _fontCss(SetupContext context, ScreenshotsDesign design) {
    const formats = {
      '.ttf': ('font/ttf', 'truetype'),
      '.otf': ('font/otf', 'opentype'),
      '.woff': ('font/woff', 'woff'),
      '.woff2': ('font/woff2', 'woff2'),
    };
    final buffer = StringBuffer();
    design.fonts.forEach((family, relativePath) {
      final file = File(p.join(context.projectRoot, relativePath));
      if (!file.existsSync()) {
        throw SetupException(
          "Font '$family' not found: ${file.path} "
          '($assetsRelativeDir/$designFileName `fonts`).',
        );
      }
      final format = formats[p.extension(file.path).toLowerCase()];
      if (format == null) {
        throw SetupException(
          "Font '$family' must be .ttf, .otf, .woff or .woff2: ${file.path}",
        );
      }
      buffer.writeln("@font-face { font-family: '$family'; "
          'src: url(data:${format.$1};base64,'
          "${base64Encode(file.readAsBytesSync())}) format('${format.$2}'); }");
    });
    return buffer.toString();
  }

  // --- Feature graphic -----------------------------------------------------

  /// Renders the Play feature graphic for [locale]. Falls back to a
  /// hand-made `feature_graphic.png` when screenshots.yaml has no
  /// `feature_graphic` entry. Returns (produced, files changed).
  Future<(bool, int)> _featureGraphic(
    SetupContext context,
    String locale,
    ScreenshotsDesign design, {
    required String fontCss,
    required String fontFamilies,
    required Set<String> unresolved,
  }) async {
    final target = File(p.join(context.projectRoot, 'fastlane', 'metadata',
        'android', locale, 'images', 'featureGraphic.png'));

    if (!design.screens.containsKey(featureGraphicScreen)) {
      return (false, _copyFeatureGraphic(context, target));
    }
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would render the feature graphic for $locale '
          '($featureGraphicWidth×$featureGraphicHeight)');
      return (true, 0);
    }

    final assetsDir = p.join(context.projectRoot, assetsRelativeDir);
    final icon = _appIcon(context);
    final html = _fill(_readTemplate(assetsDir, featureGraphicTemplateName), {
      ..._placeholders(design.textFor(featureGraphicScreen, locale),
          design.paletteFor(featureGraphicScreen)),
      'W': '$featureGraphicWidth',
      'H': '$featureGraphicHeight',
      'IMG': icon == null ? '' : _dataUri(icon),
      'SCREEN_AR': '1/1',
      'FONT_CSS': fontCss,
      'FONT_FAMILIES': fontFamilies,
      'INDEX': '1',
      'COUNT': '1',
      'LOCALE': locale,
      'DEVICE': 'feature_graphic',
      'SCREEN': featureGraphicScreen,
    }, unresolved);
    final result = await _renderTo(context, target,
        html: html,
        width: featureGraphicWidth,
        height: featureGraphicHeight);
    return (true, result.$2);
  }

  /// The 1024 app icon, used as the feature graphic's mark.
  img.Image? _appIcon(SetupContext context) {
    final candidates = [
      if (context.config.branding != null)
        p.join(context.projectRoot, context.config.branding!.iconSrc,
            'icon.png'),
      p.join(ProjectFinder.iosAssetCatalogDir(context.projectRoot),
          'AppIcon.appiconset', 'Icon-App-1024x1024@1x.png'),
    ];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      final image = img.decodePng(file.readAsBytesSync());
      if (image != null) return image;
    }
    return null;
  }

  /// Legacy path: a hand-made 1024×500 PNG committed by the user.
  /// Returns the number of changed files.
  int _copyFeatureGraphic(SetupContext context, File target) {
    final source =
        File(p.join(context.projectRoot, featureGraphicRelativePath));
    if (!source.existsSync()) return 0;
    final image = img.decodePng(source.readAsBytesSync());
    if (image == null ||
        image.width != featureGraphicWidth ||
        image.height != featureGraphicHeight) {
      throw SetupException(
        '$featureGraphicRelativePath must be a '
        '$featureGraphicWidth×$featureGraphicHeight PNG '
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
      context.out
          .writeln('  [dry-run] Would copy the hand-made feature graphic');
      return 0;
    }
    return writeBytesIfChanged(target, source.readAsBytesSync());
  }

  // --- Convergence ---------------------------------------------------------

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
      {required bool managesAndroid, required bool keepFeatureGraphic}) {
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
      if (!keepFeatureGraphic &&
          !graphicSource.existsSync() &&
          graphicTarget.existsSync()) {
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

  // --- Reporting -----------------------------------------------------------

  void _report(
    SetupContext context,
    ScreenshotsDesign design, {
    required int composed,
    required int rendered,
    required int changed,
    required Set<String> seenScreens,
    required Set<String> unresolved,
    required List<String> devices,
  }) {
    if (composed == 0) {
      context.out.writeln(
          '  ! Nothing composed — put raw captures under '
          '$rawRelativeDir/{locale}/{device}/.');
      return;
    }
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would render $composed screenshot(s) from '
          '$rawRelativeDir');
      return;
    }

    context.out.writeln(rendered > 0
        ? '  ✓ Store screenshots written to fastlane/ '
            '($rendered rendered, $changed file(s) updated)'
        : '  ✓ Store screenshots up to date');

    final unknown = design.screens.keys
        .where((screen) =>
            screen != featureGraphicScreen && !seenScreens.contains(screen))
        .toList()
      ..sort();
    if (unknown.isNotEmpty) {
      context.out.writeln(
          "  ! $designFileName describes ${unknown.join(', ')}, which "
          'match no raw capture — check the filenames under $rawRelativeDir.');
    }
    if (unresolved.isNotEmpty) {
      final names = unresolved.toList()..sort();
      context.out.writeln(
          '  ! ${names.map((n) => '{{$n}}').join(', ')} rendered empty — add '
          'the field under a screen in $designFileName, or remove it from '
          '$templateFileName.');
    }
    if (devices.any((device) => deviceSpecs[device]!.ios)) {
      context.out.writeln(
          '  → Android assets upload on the next `easy_setup deploy`; '
          'the iOS App Store upload (deliver) is not wired into deploy '
          'yet — upload fastlane/screenshots/ via `fastlane deliver` or '
          'App Store Connect for now.');
    }
  }
}

/// Reads a PNG `tEXt` value without decoding the pixels — the render stamp
/// is checked for every output on every run, so it has to be cheap.
String? pngText(Uint8List bytes, String keyword) {
  const signature = 8;
  if (bytes.length < signature + 8) return null;
  var offset = signature;
  while (offset + 8 <= bytes.length) {
    final length =
        ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    final dataStart = offset + 8;
    // tEXt chunks written by the encoder precede the pixel data.
    if (type == 'IDAT' || type == 'IEND') return null;
    if (dataStart + length > bytes.length) return null;
    if (type == 'tEXt') {
      final data = bytes.sublist(dataStart, dataStart + length);
      final separator = data.indexOf(0);
      if (separator > 0 &&
          String.fromCharCodes(data.sublist(0, separator)) == keyword) {
        return String.fromCharCodes(data.sublist(separator + 1));
      }
    }
    offset = dataStart + length + 4; // + CRC
  }
  return null;
}
