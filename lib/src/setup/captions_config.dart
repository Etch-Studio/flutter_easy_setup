import 'dart:io';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// Parsed captions.yaml for the screenshot composition layer
/// (V2_PLAN.md §5.2).
///
/// ```yaml
/// background: '#101528'      # canvas color behind the screenshot
/// text_color: '#FFFFFF'
/// font: assets/store/screenshots/font.zip   # optional BMFont zip
/// screens:
///   01_home:
///     ko: 꿈을 기록하세요
///     en-US: Record your dreams
/// ```
class CaptionsConfig {
  final String background;
  final String textColor;

  /// Project-relative path to a BMFont .zip (needed to draw captions —
  /// the bundled bitmap fonts are Latin-only).
  final String? fontPath;

  /// Screen name (raw file basename without .png) → locale → caption.
  final Map<String, Map<String, String>> screens;

  CaptionsConfig({
    this.background = '#000000',
    this.textColor = '#FFFFFF',
    this.fontPath,
    this.screens = const {},
  });

  factory CaptionsConfig.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw SetupException(
        'Captions file not found: $path (screenshots.captions).',
      );
    }
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw SetupException('Failed to parse $path:\n${e.message}');
    }
    if (doc == null) return CaptionsConfig();
    if (doc is! Map) {
      throw SetupException('$path must contain a YAML map.');
    }
    return CaptionsConfig.fromYaml(doc, path);
  }

  factory CaptionsConfig.fromYaml(Map<dynamic, dynamic> yaml, String path) {
    final screensNode = yaml['screens'];
    final screens = <String, Map<String, String>>{};
    if (screensNode is Map) {
      screensNode.forEach((screen, locales) {
        if (locales is! Map) {
          throw SetupException(
            "$path: 'screens.$screen' must map locales to captions.",
          );
        }
        screens['$screen'] = locales
            .map((locale, caption) => MapEntry('$locale', '$caption'));
      });
    } else if (screensNode != null) {
      throw SetupException("$path: 'screens' must be a map.");
    }
    return CaptionsConfig(
      background: _hex(yaml['background'], 'background', path) ?? '#000000',
      textColor: _hex(yaml['text_color'], 'text_color', path) ?? '#FFFFFF',
      fontPath: yaml['font'] == null ? null : '${yaml['font']}',
      screens: screens,
    );
  }

  static final _hexPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

  static String? _hex(Object? node, String key, String path) {
    if (node == null) return null;
    final value = '$node';
    if (!_hexPattern.hasMatch(value)) {
      throw SetupException(
        "$path: '$key' must be a #RRGGBB color (got: $value).",
      );
    }
    return value;
  }
}
