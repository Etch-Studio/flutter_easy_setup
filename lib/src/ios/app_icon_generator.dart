import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../exceptions.dart';
import '../utils/idempotent_writer.dart';

/// A class that auto-generates per-flavor iOS app icons from a 1024x1024 source image.
///
/// For each flavor, resizes to 15 unique PNG sizes and saves them
/// in AppIcon-{flavor}.appiconset/, along with a generated Contents.json.
class AppIconGenerator {
  /// App icon size definitions (filename, pixel size)
  static const List<_IconSize> _iconSizes = [
    _IconSize('Icon-App-20x20@1x.png', 20),
    _IconSize('Icon-App-20x20@2x.png', 40),
    _IconSize('Icon-App-20x20@3x.png', 60),
    _IconSize('Icon-App-29x29@1x.png', 29),
    _IconSize('Icon-App-29x29@2x.png', 58),
    _IconSize('Icon-App-29x29@3x.png', 87),
    _IconSize('Icon-App-40x40@1x.png', 40),
    _IconSize('Icon-App-40x40@2x.png', 80),
    _IconSize('Icon-App-40x40@3x.png', 120),
    _IconSize('Icon-App-60x60@2x.png', 120),
    _IconSize('Icon-App-60x60@3x.png', 180),
    _IconSize('Icon-App-76x76@1x.png', 76),
    _IconSize('Icon-App-76x76@2x.png', 152),
    _IconSize('Icon-App-83.5x83.5@2x.png', 167),
    _IconSize('Icon-App-1024x1024@1x.png', 1024),
  ];

  /// Contents.json entry definitions (19 entries)
  static const List<_ContentsEntry> _contentsEntries = [
    _ContentsEntry('Icon-App-20x20@2x.png', '20x20', '2x', 'iphone'),
    _ContentsEntry('Icon-App-20x20@3x.png', '20x20', '3x', 'iphone'),
    _ContentsEntry('Icon-App-29x29@2x.png', '29x29', '2x', 'iphone'),
    _ContentsEntry('Icon-App-29x29@3x.png', '29x29', '3x', 'iphone'),
    _ContentsEntry('Icon-App-40x40@2x.png', '40x40', '2x', 'iphone'),
    _ContentsEntry('Icon-App-40x40@3x.png', '40x40', '3x', 'iphone'),
    _ContentsEntry('Icon-App-60x60@2x.png', '60x60', '2x', 'iphone'),
    _ContentsEntry('Icon-App-60x60@3x.png', '60x60', '3x', 'iphone'),
    _ContentsEntry('Icon-App-20x20@1x.png', '20x20', '1x', 'ipad'),
    _ContentsEntry('Icon-App-20x20@2x.png', '20x20', '2x', 'ipad'),
    _ContentsEntry('Icon-App-29x29@1x.png', '29x29', '1x', 'ipad'),
    _ContentsEntry('Icon-App-29x29@2x.png', '29x29', '2x', 'ipad'),
    _ContentsEntry('Icon-App-40x40@1x.png', '40x40', '1x', 'ipad'),
    _ContentsEntry('Icon-App-40x40@2x.png', '40x40', '2x', 'ipad'),
    _ContentsEntry('Icon-App-76x76@1x.png', '76x76', '1x', 'ipad'),
    _ContentsEntry('Icon-App-76x76@2x.png', '76x76', '2x', 'ipad'),
    _ContentsEntry('Icon-App-83.5x83.5@2x.png', '83.5x83.5', '2x', 'ipad'),
    _ContentsEntry(
        'Icon-App-1024x1024@1x.png', '1024x1024', '1x', 'ios-marketing'),
  ];

  /// Generates AppIcon-{flavor}.appiconset/ in [assetCatalogDir].
  ///
  /// [projectRoot]: Flutter project root (used to resolve source image path)
  /// [assetCatalogDir]: ios/Runner/Assets.xcassets path
  /// [flavor]: flavor name
  /// [appIconPath]: 1024x1024 source image path (relative to project root)
  static void generate(
    String projectRoot,
    String assetCatalogDir,
    String flavor,
    String appIconPath, {
    bool dryRun = false,
  }) {
    final appiconsetDir = p.join(assetCatalogDir, 'AppIcon-$flavor.appiconset');
    final sourcePath = p.join(projectRoot, appIconPath);
    _generateIconSet(sourcePath, appiconsetDir, dryRun: dryRun);
  }

  /// Generates the default AppIcon.appiconset/ (v2 branding step — no
  /// flavors involved).
  static void generateDefault(
    String sourcePath,
    String assetCatalogDir, {
    bool dryRun = false,
  }) {
    _generateIconSet(
      sourcePath,
      p.join(assetCatalogDir, 'AppIcon.appiconset'),
      dryRun: dryRun,
    );
  }

  /// Deletes unused AppIcon-*.appiconset directories from [assetCatalogDir].
  ///
  /// [activeFlavors]: list of currently active flavors (only their app icons are preserved)
  /// In dry-run mode, only prints the directories that would be deleted.
  static void cleanupUnusedAppIcons(
    String assetCatalogDir,
    Set<String> activeFlavors, {
    bool dryRun = false,
  }) {
    final assetDir = Directory(assetCatalogDir);
    if (!assetDir.existsSync()) return;

    try {
      for (final entity in assetDir.listSync()) {
        if (entity is! Directory) continue;
        final dirName = p.basename(entity.path);

        // Only target AppIcon-{flavor}.appiconset pattern
        if (!dirName.startsWith('AppIcon-') || !dirName.endsWith('.appiconset')) {
          continue;
        }

        // Extract flavor name from directory name
        final flavor =
            dirName.replaceFirst('AppIcon-', '').replaceFirst('.appiconset', '');

        // Delete if not a currently configured flavor
        if (!activeFlavors.contains(flavor)) {
          if (dryRun) {
            print('  [dry-run] Would delete: ${entity.path}');
          } else {
            entity.deleteSync(recursive: true);
            print('  Deleted unused app icon: ${entity.path}');
          }
        }
      }
    } catch (e) {
      print('  Warning: Failed to cleanup app icons: $e');
    }
  }

  /// Loads the source image and generates 15 sized PNGs + Contents.json.
  static void _generateIconSet(
    String sourcePath,
    String outputDir, {
    required bool dryRun,
  }) {
    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      throw SetupException('App icon source image not found: $sourcePath');
    }

    final decoded = img.decodePng(sourceFile.readAsBytesSync());
    if (decoded == null) {
      throw SetupException('Failed to decode PNG image: $sourcePath');
    }
    if (decoded.width != 1024 || decoded.height != 1024) {
      throw SetupException(
        'App icon source must be 1024x1024, '
        'got ${decoded.width}x${decoded.height}: $sourcePath',
      );
    }
    // App Store validation rejects icons that carry an alpha channel even
    // when every pixel is opaque — always emit RGB.
    final sourceImage =
        decoded.numChannels == 4 ? decoded.convert(numChannels: 3) : decoded;

    if (dryRun) {
      print('  [dry-run] Would generate app icons in: $outputDir');
      return;
    }

    Directory(outputDir).createSync(recursive: true);

    // Generate resized icon PNGs (byte-level idempotent: unchanged files
    // are not rewritten)
    var changed = 0;
    final bytesBySize = <int, List<int>>{};
    for (final iconSize in _iconSizes) {
      final bytes = bytesBySize.putIfAbsent(iconSize.pixels, () {
        final resized = img.copyResize(
          sourceImage,
          width: iconSize.pixels,
          height: iconSize.pixels,
          interpolation: img.Interpolation.average,
        );
        return img.encodePng(resized);
      });
      changed +=
          writeBytesIfChanged(File(p.join(outputDir, iconSize.filename)), bytes);
    }

    // Generate Contents.json
    changed += writeBytesIfChanged(
      File(p.join(outputDir, 'Contents.json')),
      utf8.encode(_buildContentsJson()),
    );

    print(changed > 0
        ? '  Generated app icons: $outputDir'
        : '  App icons up to date: $outputDir');
  }

  /// Builds the Contents.json string.
  static String _buildContentsJson() {
    final images = <Map<String, dynamic>>[];
    for (final entry in _contentsEntries) {
      images.add({
        'size': entry.size,
        'idiom': entry.idiom,
        'filename': entry.filename,
        'scale': entry.scale,
      });
    }

    final contents = {
      'images': images,
      'info': {
        'version': 1,
        'author': 'easy_setup',
      },
    };

    return const JsonEncoder.withIndent('  ').convert(contents);
  }
}

/// Icon size definition (filename + pixel size)
class _IconSize {
  final String filename;
  final int pixels;
  const _IconSize(this.filename, this.pixels);
}

/// Contents.json entry definition
class _ContentsEntry {
  final String filename;
  final String size;
  final String scale;
  final String idiom;
  const _ContentsEntry(this.filename, this.size, this.scale, this.idiom);
}
