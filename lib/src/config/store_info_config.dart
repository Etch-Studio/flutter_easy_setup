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

  /// Allowed keys of the `review_information:` section (deliver's
  /// review_information filenames).
  static const reviewInformationKeys = [
    'first_name',
    'last_name',
    'phone_number',
    'email_address',
    'demo_user',
    'demo_password',
    'notes',
  ];

  /// Allowed keys of the `age_rating:` section (App Store Connect
  /// ageRatingDeclarations attributes, snake_case). Values pass through:
  /// NONE / INFREQUENT_OR_MILD / FREQUENT_OR_INTENSE for content
  /// descriptors, booleans for the yes/no questions.
  static const ageRatingKeys = [
    'alcohol_tobacco_or_drug_use_or_references',
    'contests',
    'gambling',
    'gambling_simulated',
    'guns_or_other_weapons',
    'horror_or_fear_themes',
    'mature_or_suggestive_themes',
    'medical_or_treatment_information',
    'profanity_or_crude_humor',
    'sexual_content_graphic_and_nudity',
    'sexual_content_or_nudity',
    'violence_cartoon_or_fantasy',
    'violence_realistic',
    'violence_realistic_prolonged_graphic_or_sadistic',
    'advertising',
    'age_assurance',
    'health_or_wellness_topics',
    'loot_box',
    'messaging_and_chat',
    'parental_controls',
    'unrestricted_web_access',
    'user_generated_content',
    'age_rating_override',
    'age_rating_override_v2',
    'korea_age_rating_override',
    'kids_age_band',
    'developer_age_rating_info_url',
  ];

  final String? copyright;
  final String? primaryCategory;
  final String? secondaryCategory;

  /// Age rating questionnaire answers (snake_case keys).
  final Map<String, Object?> ageRating;

  /// App Review contact / demo account. Also required in practice for the
  /// very first deliver run — without any review detail on the app record,
  /// deliver crashes fetching it.
  final Map<String, String> reviewInformation;

  final Map<String, StoreLocaleInfo> locales;

  StoreInfoConfig({
    this.copyright,
    this.primaryCategory,
    this.secondaryCategory,
    this.ageRating = const {},
    this.reviewInformation = const {},
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
    final ageRatingNode = yaml['age_rating'];
    final ageRating = <String, Object?>{};
    if (ageRatingNode is Map) {
      ageRatingNode.forEach((key, value) {
        if (!ageRatingKeys.contains('$key')) {
          throw SetupException(
            "$path: unknown field 'age_rating.$key' — allowed: "
            '${ageRatingKeys.join(', ')}.',
          );
        }
        // Quoted booleans would reach ASC as the string "false" — reject.
        if (value is String &&
            (value.toLowerCase() == 'true' || value.toLowerCase() == 'false')) {
          throw SetupException(
            "$path: 'age_rating.$key' must be a YAML boolean — remove the "
            'quotes.',
          );
        }
        // null is meaningful (e.g. kids_age_band: null) — keep it.
        ageRating['$key'] =
            (value is bool || value == null) ? value : '$value';
      });
    } else if (ageRatingNode != null) {
      throw SetupException("$path: 'age_rating' must be a map.");
    }

    final reviewNode = yaml['review_information'];
    final review = <String, String>{};
    if (reviewNode is Map) {
      reviewNode.forEach((key, value) {
        if (!reviewInformationKeys.contains('$key')) {
          throw SetupException(
            "$path: unknown field 'review_information.$key' — allowed: "
            '${reviewInformationKeys.join(', ')}.',
          );
        }
        review['$key'] = '$value'.trim();
      });
    } else if (reviewNode != null) {
      throw SetupException("$path: 'review_information' must be a map.");
    }

    return StoreInfoConfig(
      copyright: _string(yaml['copyright'], 'copyright', path),
      primaryCategory:
          _string(yaml['primary_category'], 'primary_category', path),
      secondaryCategory:
          _string(yaml['secondary_category'], 'secondary_category', path),
      ageRating: ageRating,
      reviewInformation: review,
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
