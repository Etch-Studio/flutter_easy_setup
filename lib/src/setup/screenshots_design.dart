import 'dart:io';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// Parsed `assets/store/screenshots/screenshots.yaml` — the copy and
/// palette source for the marketing screenshot renderer (V2_PLAN.md §5.2,
/// layer ②).
///
/// ```yaml
/// fonts:
///   Display: assets/fonts/Pretendard-Bold.ttf
/// defaults:
///   palette: default
///   crop_bottom: 0
///   text:
///     ko: { eyebrow: 드림로그 }
/// palettes:
///   default:
///     bg: '#0d1017'
///     title: '#ffffff'
/// screens:
///   01_home:
///     palette: default
///     crop_bottom: 140
///     text:
///       ko: { title: "꿈을 기록하세요", subtitle: "눈뜨자마자 30초" }
/// ```
///
/// Palette entries become `{{C_BG}}`-style template placeholders and text
/// fields become `{{TITLE}}`-style ones, so the template and this file can
/// grow together without touching Dart.
class ScreenshotsDesign {
  /// Placeholder names the renderer supplies itself; a text field may not
  /// shadow one.
  static const reservedPlaceholders = {
    'W',
    'H',
    'IMG',
    'SCREEN_AR',
    'FONT_CSS',
    'FONT_FAMILIES',
    'INDEX',
    'COUNT',
    'LOCALE',
    'DEVICE',
    'SCREEN',
  };

  /// Prefix owned by palette entries. Text fields may not use it, or a
  /// caption could pose as a color and skip the CSS-value validation.
  static const palettePlaceholderPrefix = 'C_';

  /// Font family name → project-relative font file.
  final Map<String, String> fonts;

  /// Palette name → CSS property value (`bg`, `accent`, ...).
  final Map<String, Map<String, String>> palettes;

  final String? defaultPalette;
  final int defaultCropBottom;

  /// Locale → field → value, used when a screen does not set the field.
  final Map<String, Map<String, String>> defaultText;

  /// Screen id (raw capture basename, without `.png`) → its design.
  final Map<String, ScreenDesign> screens;

  ScreenshotsDesign({
    this.fonts = const {},
    this.palettes = const {},
    this.defaultPalette,
    this.defaultCropBottom = 0,
    this.defaultText = const {},
    this.screens = const {},
  });

  factory ScreenshotsDesign.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return ScreenshotsDesign();
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw SetupException('Failed to parse $path:\n${e.message}');
    }
    if (doc == null) return ScreenshotsDesign();
    if (doc is! Map) throw SetupException('$path must contain a YAML map.');
    return ScreenshotsDesign.fromYaml(doc, path);
  }

  factory ScreenshotsDesign.fromYaml(Map<dynamic, dynamic> yaml, String path) {
    final palettes = <String, Map<String, String>>{};
    _asMap(yaml['palettes'], 'palettes', path).forEach((name, entries) {
      final values = <String, String>{};
      _asMap(entries, 'palettes.$name', path).forEach((key, value) {
        // Must survive uppercasing into a {{C_*}} placeholder; a hyphen
        // would produce a token the template can never match.
        _requireIdentifier('$key', 'palettes.$name.$key', path);
        values['$key'] = _cssValue('$value', 'palettes.$name.$key', path);
      });
      palettes['$name'] = values;
    });

    final defaults = _asMap(yaml['defaults'], 'defaults', path);
    final defaultPalette =
        defaults['palette'] == null ? null : '${defaults['palette']}';
    final defaultText = _text(defaults['text'], 'defaults.text', path);

    final screens = <String, ScreenDesign>{};
    _asMap(yaml['screens'], 'screens', path).forEach((id, node) {
      final screen = _asMap(node, 'screens.$id', path);
      for (final key in screen.keys) {
        if (!const {'palette', 'crop_bottom', 'text'}.contains('$key')) {
          throw SetupException(
            "$path: unknown key 'screens.$id.$key'. A screen takes "
            "'palette', 'crop_bottom' and 'text'.",
          );
        }
      }
      screens['$id'] = ScreenDesign(
        palette: screen['palette'] == null ? null : '${screen['palette']}',
        cropBottom: _cropBottom(screen['crop_bottom'], 'screens.$id', path),
        text: _text(screen['text'], 'screens.$id.text', path),
      );
    });

    final design = ScreenshotsDesign(
      fonts: _asMap(yaml['fonts'], 'fonts', path)
          .map((family, file) => MapEntry('$family', '$file')),
      palettes: palettes,
      defaultPalette: defaultPalette,
      defaultCropBottom:
          _cropBottom(defaults['crop_bottom'], 'defaults', path) ?? 0,
      defaultText: defaultText,
      screens: screens,
    );
    design._validatePaletteNames(path);
    return design;
  }

  /// The palette a screen renders with, or an empty map when none is
  /// configured (the template's own CSS fallbacks then apply).
  Map<String, String> paletteFor(String screenId) {
    final name = screens[screenId]?.palette ?? defaultPalette;
    if (name == null) return const {};
    return palettes[name] ?? const {};
  }

  int cropBottomFor(String screenId) =>
      screens[screenId]?.cropBottom ?? defaultCropBottom;

  /// Text fields for one screen in one locale, with `defaults.text`
  /// filling any field the screen does not set.
  Map<String, String> textFor(String screenId, String locale) => {
        ...?defaultText[locale],
        ...?screens[screenId]?.text[locale],
      };

  void _validatePaletteNames(String path) {
    void check(String? name, String where) {
      if (name == null || palettes.containsKey(name)) return;
      throw SetupException(
        "$path: $where references palette '$name', which is not defined "
        "under 'palettes'${palettes.isEmpty ? '' : ' (have: ${palettes.keys.join(', ')})'}.",
      );
    }

    check(defaultPalette, 'defaults.palette');
    screens.forEach((id, screen) => check(screen.palette, 'screens.$id'));
  }

  // --- Parsing helpers -----------------------------------------------------

  static Map<dynamic, dynamic> _asMap(
      Object? node, String where, String path) {
    if (node == null) return const {};
    if (node is! Map) throw SetupException("$path: '$where' must be a map.");
    return node;
  }

  static int? _cropBottom(Object? node, String where, String path) {
    if (node == null) return null;
    final value = node is int ? node : int.tryParse('$node');
    if (value == null || value < 0) {
      throw SetupException(
        "$path: '$where.crop_bottom' must be a non-negative number of "
        'pixels (got: $node).',
      );
    }
    return value;
  }

  static Map<String, Map<String, String>> _text(
      Object? node, String where, String path) {
    final result = <String, Map<String, String>>{};
    _asMap(node, where, path).forEach((locale, fields) {
      final values = <String, String>{};
      _asMap(fields, '$where.$locale', path).forEach((field, value) {
        final key = '$field';
        _requireIdentifier(key, '$where.$locale.$key', path);
        if (reservedPlaceholders.contains(key.toUpperCase())) {
          throw SetupException(
            "$path: text field '$key' would shadow the built-in "
            '{{${key.toUpperCase()}}} placeholder — rename it.',
          );
        }
        if (key.toUpperCase().startsWith(palettePlaceholderPrefix)) {
          throw SetupException(
            "$path: text field '$key' becomes "
            '{{${key.toUpperCase()}}}, which belongs to the palette — '
            "rename it, or move it under 'palettes'.",
          );
        }
        values[key] = '$value';
      });
      result['$locale'] = values;
    });
    return result;
  }

  static final _identifier = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

  /// Keys become `{{PLACEHOLDER}}` names, which are `[A-Z0-9_]` only.
  static void _requireIdentifier(String key, String where, String path) {
    if (_identifier.hasMatch(key)) return;
    throw SetupException(
      "$path: '$where' must be a plain identifier (a letter, then letters, "
      'digits or underscores) — it becomes a {{PLACEHOLDER}} name.',
    );
  }

  /// Palette values land inside a CSS declaration, so gradients and
  /// `rgba()` are welcome but anything that could close the rule (or the
  /// surrounding `<style>`) is not.
  static String _cssValue(String value, String where, String path) {
    if (RegExp(r'[{}<>;]').hasMatch(value) || value.contains('\n')) {
      throw SetupException(
        "$path: '$where' must be a plain CSS value (got: $value). "
        "'{', '}', '<', '>' and ';' are not allowed.",
      );
    }
    return value;
  }
}

/// One screen's design overrides.
class ScreenDesign {
  final String? palette;
  final int? cropBottom;
  final Map<String, Map<String, String>> text;

  ScreenDesign({this.palette, this.cropBottom, this.text = const {}});
}
