import 'dart:io';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// Parsed `easy_setup_store_info.yaml` — the store listing texts that are
/// otherwise typed into the App Store Connect / Play Console web UIs.
///
/// One source drives both stores: shared fields (name, description,
/// release notes) are written to both fastlane trees; `keywords`,
/// `subtitle`, and `promotional_text` are iOS-only, `short_description`
/// is Android-only. Character limits are enforced at parse time so a
/// too-long text fails before any upload starts.
class StoreInfoConfig {
  /// Conventional file name, next to easy_setup.yaml.
  static const fileName = 'easy_setup_store_info.yaml';

  final String? copyright;
  final String? primaryCategory;
  final String? secondaryCategory;
  final Map<String, StoreLocaleInfo> locales;

  StoreInfoConfig({
    this.copyright,
    this.primaryCategory,
    this.secondaryCategory,
    this.locales = const {},
  });

  factory StoreInfoConfig.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw SetupException('Store info file not found: $path');
    }
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw SetupException('Failed to parse $path:\n${e.message}');
    }
    if (doc is! Map) {
      throw SetupException('$path must contain a YAML map.');
    }
    return StoreInfoConfig.fromYaml(doc, path);
  }

  factory StoreInfoConfig.fromYaml(Map<dynamic, dynamic> yaml, String path) {
    final localesNode = yaml['locales'];
    if (localesNode is! Map || localesNode.isEmpty) {
      throw SetupException(
        "$path: 'locales' must map at least one locale (e.g. ko, en-US) "
        'to its listing texts.',
      );
    }
    return StoreInfoConfig(
      copyright: _string(yaml['copyright'], 'copyright', path),
      primaryCategory:
          _string(yaml['primary_category'], 'primary_category', path),
      secondaryCategory:
          _string(yaml['secondary_category'], 'secondary_category', path),
      locales: localesNode.map((locale, node) {
        if (node is! Map) {
          throw SetupException(
              "$path: 'locales.$locale' must be a map of fields.");
        }
        return MapEntry(
            '$locale', StoreLocaleInfo.fromYaml(node, '$locale', path));
      }),
    );
  }

  static String? _string(Object? node, String key, String path) {
    if (node == null) return null;
    if (node is String || node is num) return '$node'.trim();
    throw SetupException("$path: '$key' must be a string.");
  }
}

/// Listing texts for one locale. Field → store mapping and limits follow
/// App Store Connect / Play Console rules.
class StoreLocaleInfo {
  /// (field, limit, iOS, Android) — the single source of truth for
  /// validation and generation.
  static const fields = [
    (name: 'name', limit: 30, ios: true, android: true),
    (name: 'subtitle', limit: 30, ios: true, android: false),
    (name: 'description', limit: 4000, ios: true, android: true),
    (name: 'keywords', limit: 100, ios: true, android: false),
    (name: 'promotional_text', limit: 170, ios: true, android: false),
    (name: 'release_notes', limit: 4000, ios: true, android: true),
    (name: 'short_description', limit: 80, ios: false, android: true),
    (name: 'support_url', limit: 0, ios: true, android: false),
    (name: 'marketing_url', limit: 0, ios: true, android: false),
    (name: 'privacy_url', limit: 0, ios: true, android: false),
  ];

  /// Field name → value, validated.
  final Map<String, String> values;

  StoreLocaleInfo(this.values);

  factory StoreLocaleInfo.fromYaml(
      Map<dynamic, dynamic> yaml, String locale, String path) {
    final known = {for (final field in fields) field.name: field};
    final values = <String, String>{};
    yaml.forEach((key, node) {
      final field = known['$key'];
      if (field == null) {
        throw SetupException(
          "$path: unknown field 'locales.$locale.$key' — allowed: "
          '${known.keys.join(', ')}.',
        );
      }
      final value = '$node'.trimRight();
      if (field.limit > 0 && value.length > field.limit) {
        throw SetupException(
          "$path: 'locales.$locale.$key' is ${value.length} characters — "
          'the store limit is ${field.limit}.',
        );
      }
      values['$key'] = value;
    });
    if (!values.containsKey('name')) {
      throw SetupException(
          "$path: 'locales.$locale.name' is required (store display name).");
    }
    return StoreLocaleInfo(values);
  }

  String? operator [](String field) => values[field];
}
