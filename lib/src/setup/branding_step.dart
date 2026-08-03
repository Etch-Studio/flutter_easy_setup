import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';
import '../ios/app_icon_generator.dart';
import '../utils/project_finder.dart';
import 'setup_step.dart';

/// App icon pipeline (V2_PLAN.md §5.1, in-house implementation — §10.2
/// decision): only the source assets live in git, everything else is
/// regenerated from them.
///
/// Sources in `branding.icon_src`:
/// - `icon.png` — 1024×1024, **no alpha** (App Store rejects transparency)
/// - `fg.png` / `bg.png` — optional, Android adaptive icon layers (1024,
///   fg content should stay inside the central 66% safe area)
/// - `mono.png` — optional, Android 13+ themed icon (needs fg/bg too)
///
/// Outputs:
/// - iOS `AppIcon.appiconset` (15 sizes + Contents.json)
/// - Android legacy `mipmap-*/ic_launcher.png`
/// - Android adaptive layers + `mipmap-anydpi-v26/ic_launcher.xml`
class BrandingStep extends SetupStep {
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

    final icon = _loadRequired(context, srcDir, 'icon.png');
    _rejectAlpha(icon.$2, p.join(srcDir, 'icon.png'));

    final fg = _loadOptional(context, srcDir, 'fg.png');
    final bg = _loadOptional(context, srcDir, 'bg.png');
    final mono = _loadOptional(context, srcDir, 'mono.png');
    if (fg != null) _checkSafeArea(context, fg.$2);
    if ((fg == null) != (bg == null)) {
      context.out.writeln(
          '  ! Adaptive icons need BOTH fg.png and bg.png — only one was '
          'found, skipping the adaptive layers.');
    }
    if (mono != null && (fg == null || bg == null)) {
      context.out.writeln(
          '  ! mono.png needs the adaptive layers (fg.png + bg.png) — '
          'skipping the themed icon.');
    }

    _generateIos(context, icon.$1);
    _generateAndroidLegacy(context, icon.$2);
    if (fg != null && bg != null) {
      _generateAndroidAdaptive(context, fg.$2, bg.$2, mono?.$2);
      if (mono == null) {
        // Converge: a removed mono.png removes its layers.
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

  (String, img.Image) _loadRequired(
      SetupContext context, String srcDir, String name) {
    final loaded = _loadOptional(context, srcDir, name);
    if (loaded == null) {
      throw SetupException(
        '${p.join(srcDir, name)} not found — the branding step needs a '
        '1024×1024 $name (see branding.icon_src).',
      );
    }
    return loaded;
  }

  (String, img.Image)? _loadOptional(
      SetupContext context, String srcDir, String name) {
    final path = p.join(srcDir, name);
    final file = File(path);
    if (!file.existsSync()) return null;
    final image = img.decodePng(file.readAsBytesSync());
    if (image == null) {
      throw SetupException('Failed to decode PNG image: $path');
    }
    if (image.width != 1024 || image.height != 1024) {
      throw SetupException(
        '$name must be 1024×1024, got ${image.width}×${image.height}: $path',
      );
    }
    return (path, image);
  }

  /// App Store rejects icons with transparency.
  void _rejectAlpha(img.Image icon, String path) {
    if (icon.numChannels < 4) return;
    for (final pixel in icon) {
      if (pixel.a < pixel.maxChannelValue) {
        throw SetupException(
          '$path contains transparent pixels — the App Store rejects icons '
          'with an alpha channel. Flatten it onto a solid background.',
        );
      }
    }
  }

  /// Android adaptive foregrounds get masked/scaled — content outside the
  /// central 66% may be clipped.
  void _checkSafeArea(SetupContext context, img.Image fg) {
    if (fg.numChannels < 4) {
      context.out.writeln(
          '  ! fg.png has no alpha channel — the whole square is treated as '
          'content, which will be clipped by adaptive icon masks.');
      return;
    }
    final margin = (1024 * (1 - 0.66) / 2).round();
    final low = margin, high = 1024 - margin;
    var outside = 0;
    for (final pixel in fg) {
      if (pixel.a == 0) continue;
      if (pixel.x < low || pixel.x >= high || pixel.y < low || pixel.y >= high) {
        outside++;
      }
    }
    if (outside > 0) {
      context.out.writeln(
          '  ! fg.png has $outside opaque pixel(s) outside the central 66% '
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
    final bytes = img.encodePng(resized);
    final file = File(path);
    if (file.existsSync()) {
      final existing = file.readAsBytesSync();
      if (existing.length == bytes.length) {
        var identical = true;
        for (var i = 0; i < bytes.length; i++) {
          if (existing[i] != bytes[i]) {
            identical = false;
            break;
          }
        }
        if (identical) return 0;
      }
    }
    file.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return 1;
  }
}
