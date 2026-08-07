import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';
import '../ios/app_icon_generator.dart';
import '../utils/idempotent_writer.dart';
import '../utils/project_finder.dart';
import 'setup_step.dart';

/// App icon pipeline (V2_PLAN.md §5.1, in-house implementation — §10.2
/// decision): only the source assets live in git, everything else is
/// regenerated from them.
///
/// Sources in `branding.icon_src`, each either an `.svg` (preferred — a
/// text source an AI skill or a designer can rewrite and diff) or a
/// ready-made 1024×1024 `.png`. When both exist the SVG wins and the PNG
/// is simply its render output.
///
/// - `icon` — the app icon. Must paint the full canvas: the App Store
///   rejects any transparency.
/// - `fg` / `bg` — optional, Android adaptive icon layers (fg content
///   should stay inside the central 66% safe area)
/// - `mono` — optional, Android 13+ themed icon (needs fg/bg too)
///
/// Outputs:
/// - iOS `AppIcon.appiconset` (15 sizes + Contents.json)
/// - Android legacy `mipmap-*/ic_launcher.png`
/// - Android adaptive layers + `mipmap-anydpi-v26/ic_launcher.xml`
class BrandingStep extends SetupStep {
  /// Every icon source is authored on this square canvas.
  static const canvas = 1024;

  static const skillRelativePath = '.claude/skills/app-icon/SKILL.md';

  /// Legacy launcher sizes: 48dp × density.
  static const launcherSizes = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  /// Adaptive layer sizes: 108dp × density.
  static const adaptiveSizes = {
    'mdpi': 108,
    'hdpi': 162,
    'xhdpi': 216,
    'xxhdpi': 324,
    'xxxhdpi': 432,
  };

  @override
  String get name => 'branding';

  @override
  bool isConfigured(ProjectConfig config) => config.branding != null;

  @override
  Future<void> run(SetupContext context) async {
    final srcDir = p.join(context.projectRoot, context.config.branding!.iconSrc);

    if (_installSkill(context) > 0) {
      context.out.writeln('  ✓ Installed the app-icon Claude skill');
    }

    final icon = await _loadRequired(context, srcDir, 'icon');
    if (icon == null) return; // dry-run without a rendered PNG yet.
    // Re-checked here because a hand-supplied icon.png never went through
    // the render-time check inside _load.
    _rejectAlpha(icon.$2, icon.$1);

    final fg = await _load(context, srcDir, 'fg');
    final bg = await _load(context, srcDir, 'bg');
    final mono = await _load(context, srcDir, 'mono');
    if (fg != null) _checkSafeArea(context, fg.$2);
    if ((fg == null) != (bg == null)) {
      context.out.writeln(
          '  ! Adaptive icons need BOTH fg and bg — only one was found, '
          'skipping the adaptive layers.');
    }
    if (mono != null && (fg == null || bg == null)) {
      context.out.writeln(
          '  ! mono needs the adaptive layers (fg + bg) — skipping the '
          'themed icon.');
    }

    _generateIos(context, icon.$1);
    _generateAndroidLegacy(context, icon.$2);
    if (fg != null && bg != null) {
      _generateAndroidAdaptive(context, fg.$2, bg.$2, mono?.$2);
      if (mono == null) {
        // Converge: a removed mono source removes its layers.
        _removeOutputs(context, ['ic_launcher_monochrome.png'],
            what: 'themed monochrome layers');
      }
    } else {
      // Converge: removed adaptive sources remove the adaptive outputs —
      // otherwise the stale anydpi-v26 XML keeps overriding the legacy PNG.
      _removeOutputs(
        context,
        [
          'ic_launcher_foreground.png',
          'ic_launcher_background.png',
          'ic_launcher_monochrome.png',
        ],
        alsoXml: true,
        what: 'stale adaptive icon outputs',
      );
    }
  }

  /// Deletes generated adaptive outputs that no longer have sources.
  void _removeOutputs(
    SetupContext context,
    List<String> layerNames, {
    bool alsoXml = false,
    required String what,
  }) {
    final resDir = ProjectFinder.androidResDir(context.projectRoot);
    final targets = <File>[
      for (final density in adaptiveSizes.keys)
        for (final name in layerNames)
          File(p.join(resDir, 'mipmap-$density', name)),
      if (alsoXml)
        File(p.join(resDir, 'mipmap-anydpi-v26', 'ic_launcher.xml')),
    ].where((file) => file.existsSync()).toList();
    if (targets.isEmpty) return;
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would remove ${targets.length} $what file(s)');
      return;
    }
    for (final file in targets) {
      file.deleteSync();
    }
    context.out.writeln('  ✓ Removed ${targets.length} $what file(s)');
  }

  // --- Source loading & validation -----------------------------------------

  Future<(String, img.Image)?> _loadRequired(
      SetupContext context, String srcDir, String base) async {
    final loaded = await _load(context, srcDir, base, mustBeOpaque: true);
    if (loaded != null) return loaded;
    if (context.dryRun && File(p.join(srcDir, '$base.svg')).existsSync()) {
      context.out.writeln(
          '  [dry-run] $base.svg has not been rendered yet — run without '
          '--dry-run to see the full icon report.');
      return null;
    }
    throw SetupException(
      'No $base source in $srcDir — the branding step needs $base.svg '
      '(a $canvas×$canvas SVG) or a $canvas×$canvas $base.png. '
      'See branding.icon_src.',
    );
  }

  /// Loads one icon layer, preferring the SVG source and rasterizing it to
  /// the sibling PNG. Returns the PNG path and its decoded image, or null
  /// when neither source exists.
  ///
  /// With [mustBeOpaque] the render is rejected — before anything is
  /// written — if the artwork leaves the canvas see-through, so a failed
  /// check never replaces a previously good icon.png.
  Future<(String, img.Image)?> _load(
    SetupContext context,
    String srcDir,
    String base, {
    bool mustBeOpaque = false,
  }) async {
    final pngPath = p.join(srcDir, '$base.png');
    final svg = File(p.join(srcDir, '$base.svg'));

    if (svg.existsSync()) {
      if (context.dryRun) {
        context.out.writeln(
            '  [dry-run] Would render $base.svg → $base.png '
            '($canvas×$canvas)');
        // Fall through to a previously rendered PNG so the rest of the
        // dry-run report stays accurate.
      } else {
        final rendered = await _rasterize(context, svg);
        if (mustBeOpaque) _rejectAlpha(rendered, svg.path);
        final changed =
            writeBytesIfChanged(File(pngPath), img.encodePng(rendered));
        context.out.writeln(changed > 0
            ? '  ✓ Rendered $base.svg → $base.png ($canvas×$canvas)'
            : '  ✓ $base.png up to date');
        return (pngPath, rendered);
      }
    }

    final png = File(pngPath);
    if (!png.existsSync()) return null;
    final image = img.decodePng(png.readAsBytesSync());
    if (image == null) {
      throw SetupException('Failed to decode PNG image: $pngPath');
    }
    if (image.width != canvas || image.height != canvas) {
      throw SetupException(
        '$base.png must be $canvas×$canvas, got '
        '${image.width}×${image.height}: $pngPath',
      );
    }
    return (pngPath, image);
  }

  /// Renders an SVG source to a [canvas]×[canvas] bitmap.
  ///
  /// Always onto a transparent backdrop: the browser must not invent an
  /// opaque background, or artwork that fails to cover the canvas would
  /// silently pass the App Store transparency check.
  Future<img.Image> _rasterize(SetupContext context, File svg) async {
    final source = svg.readAsStringSync();
    if (!source.contains('viewBox')) {
      context.out.writeln(
          '  ! ${p.basename(svg.path)} has no viewBox — without one the '
          'artwork cannot scale to $canvas×$canvas and will be cropped.');
    }
    return context.renderer.render(
      html: svgPage(source),
      width: canvas,
      height: canvas,
      transparent: true,
    );
  }

  /// Wraps an SVG document in a bare page sized to the icon canvas.
  ///
  /// The XML prolog and any doctype are dropped: they are legal in a
  /// standalone `.svg` file but not inside an HTML body.
  static String svgPage(String svg) {
    final inline = svg
        .replaceAll(RegExp(r'<\?xml[^>]*\?>'), '')
        .replaceAll(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '')
        .trim();
    return '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  html, body {
    margin: 0; padding: 0;
    width: ${canvas}px; height: ${canvas}px;
    overflow: hidden;
    background: transparent;
  }
  svg { display: block; width: ${canvas}px; height: ${canvas}px; }
</style>
</head>
<body>
$inline
</body>
</html>
''';
  }

  /// App Store rejects icons with transparency.
  void _rejectAlpha(img.Image icon, String path) {
    if (icon.numChannels < 4) return;
    for (final pixel in icon) {
      if (pixel.a < pixel.maxChannelValue) {
        throw SetupException(
          '$path contains transparent pixels — the App Store rejects icons '
          'with an alpha channel. Paint the full $canvas×$canvas canvas '
          '(a full-bleed background rect in icon.svg), or flatten the PNG '
          'onto a solid background.',
        );
      }
    }
  }

  /// Android adaptive foregrounds get masked/scaled — content outside the
  /// central 66% may be clipped.
  void _checkSafeArea(SetupContext context, img.Image fg) {
    if (fg.numChannels < 4) {
      context.out.writeln(
          '  ! fg has no alpha channel — the whole square is treated as '
          'content, which will be clipped by adaptive icon masks.');
      return;
    }
    final margin = (canvas * (1 - 0.66) / 2).round();
    final low = margin, high = canvas - margin;
    var outside = 0;
    for (final pixel in fg) {
      if (pixel.a == 0) continue;
      if (pixel.x < low ||
          pixel.x >= high ||
          pixel.y < low ||
          pixel.y >= high) {
        outside++;
      }
    }
    if (outside > 0) {
      context.out.writeln(
          '  ! fg has $outside opaque pixel(s) outside the central 66% '
          'safe area — adaptive icon masks may clip them.');
    }
  }

  // --- Output generation ---------------------------------------------------

  void _generateIos(SetupContext context, String iconPath) {
    final catalogDir = ProjectFinder.iosAssetCatalogDir(context.projectRoot);
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would generate AppIcon.appiconset (15 sizes) in '
          '$catalogDir');
      return;
    }
    AppIconGenerator.generateDefault(iconPath, catalogDir);
    context.out.writeln('  ✓ iOS AppIcon.appiconset (15 sizes)');
  }

  void _generateAndroidLegacy(SetupContext context, img.Image icon) {
    final resDir = ProjectFinder.androidResDir(context.projectRoot);
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would generate mipmap-*/ic_launcher.png '
          '(${launcherSizes.values.join('/')}) in $resDir');
      return;
    }
    var changed = 0;
    launcherSizes.forEach((density, size) {
      changed += _writePng(
          p.join(resDir, 'mipmap-$density', 'ic_launcher.png'), icon, size);
    });
    context.out.writeln(changed > 0
        ? '  ✓ Android ic_launcher.png (${launcherSizes.length} densities)'
        : '  ✓ Android ic_launcher.png up to date');
  }

  void _generateAndroidAdaptive(
      SetupContext context, img.Image fg, img.Image bg, img.Image? mono) {
    final resDir = ProjectFinder.androidResDir(context.projectRoot);
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would generate adaptive icon layers'
          '${mono != null ? ' + themed monochrome' : ''} and '
          'mipmap-anydpi-v26/ic_launcher.xml in $resDir');
      return;
    }
    var changed = 0;
    adaptiveSizes.forEach((density, size) {
      final dir = p.join(resDir, 'mipmap-$density');
      changed += _writePng(p.join(dir, 'ic_launcher_foreground.png'), fg, size);
      changed += _writePng(p.join(dir, 'ic_launcher_background.png'), bg, size);
      if (mono != null) {
        changed +=
            _writePng(p.join(dir, 'ic_launcher_monochrome.png'), mono, size);
      }
    });

    final xml = StringBuffer('''
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
''');
    if (mono != null) {
      xml.writeln(
          '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>');
    }
    xml.writeln('</adaptive-icon>');
    final xmlFile =
        File(p.join(resDir, 'mipmap-anydpi-v26', 'ic_launcher.xml'));
    final xmlText = xml.toString();
    if (!xmlFile.existsSync() || xmlFile.readAsStringSync() != xmlText) {
      xmlFile.createSync(recursive: true);
      xmlFile.writeAsStringSync(xmlText);
      changed++;
    }

    context.out.writeln(changed > 0
        ? '  ✓ Android adaptive icon layers'
            '${mono != null ? ' + themed monochrome' : ''}'
        : '  ✓ Android adaptive icons up to date');
  }

  /// Resizes and writes a PNG; returns 1 when the file content changed.
  int _writePng(String path, img.Image source, int size) {
    final resized = img.copyResize(
      source,
      width: size,
      height: size,
      interpolation: img.Interpolation.average,
    );
    return writeBytesIfChanged(File(path), img.encodePng(resized));
  }

  // --- AI skill ------------------------------------------------------------

  int _installSkill(SetupContext context) {
    if (context.dryRun) return 0;
    final gitRoot =
        ProjectFinder.findGitRoot(context.projectRoot) ?? context.projectRoot;
    final iconSrc = p.join(p.relative(context.projectRoot, from: gitRoot),
        context.config.branding!.iconSrc);
    return writeIfAbsent(File(p.join(gitRoot, skillRelativePath)),
        _skillDefinition(p.normalize(iconSrc)));
  }

  String _skillDefinition(String iconSrc) => '''
---
name: app-icon
description: Design the app icon as an SVG that easy_setup renders into
  every iOS and Android size. Use when asked to create, redesign, or
  tweak the app icon / launcher icon / adaptive icon.
---

# App icon

You author **`$iconSrc/icon.svg`**. `easy_setup setup --only branding`
renders it to a $canvas×$canvas PNG and fans that out to the 15 iOS
sizes and 5 Android densities. Never hand-edit anything under
`Assets.xcassets` or `mipmap-*` — it is generated and will be overwritten.

## 1. Gather the brand

Read these before drawing anything:

- `easy_setup.yaml` — `app.name`, and `site.mood` / `site.features` if set
- `easy_setup_store_info.yaml` — the store name, subtitle and description
- `site/style.css` — if the promo site exists, its CSS custom properties
  already define the brand palette. **Reuse those exact colors** so the
  icon, the site and the screenshots read as one product.

## 2. Draw `icon.svg`

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $canvas $canvas">
  <rect width="$canvas" height="$canvas" fill="#..."/>
  <!-- artwork -->
</svg>
```

Hard requirements — the render or the store review fails otherwise:

- **`viewBox="0 0 $canvas $canvas"`.** Without it the artwork cannot scale.
- **Paint the whole canvas.** A full-bleed background rect is mandatory:
  any transparent pixel makes App Store validation reject the build.
- **No rounded corners, no drop shadow outside the square.** iOS and
  Android apply their own mask; baking one in produces a double corner.
- **Self-contained.** No `<image href>`, no external stylesheets, no web
  fonts. Avoid `<text>` entirely — the renderer's font set differs per
  machine, so text must be drawn as paths to stay reproducible.
- **Legible at 40px.** The icon is mostly seen tiny: one strong shape,
  two or three colors, no thin strokes, no fine detail, no wordmark.

## 3. Android adaptive icon (optional but recommended)

Add `$iconSrc/fg.svg` and `$iconSrc/bg.svg`:

- `bg.svg` — full-bleed background, no transparency.
- `fg.svg` — the symbol on a **transparent** background, with all content
  inside the central 66% (i.e. inset ~174 units on every side of the
  $canvas canvas). Android masks the outer ring away.
- `mono.svg` — optional Android 13+ themed icon: the same silhouette in a
  single opaque color on transparency.

## 4. Render and check

```sh
easy_setup setup --only branding
```

Then Read `$iconSrc/icon.png` (the render, not the SVG) and judge it as
an image: is the shape readable, is the composition centred, does it
match the palette? Iterate on the SVG — never on the PNG.
''';
}
