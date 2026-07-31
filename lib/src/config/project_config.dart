import 'dart:io';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// Root model for the v2 `easy_setup.yaml` schema.
///
/// v2 drops the v1 `easy_setup:` root key. Every section except `app` is
/// optional — commands only act on the sections that are present, so a
/// minimal config is just:
///
/// ```yaml
/// app:
///   name: MyApp
///   bundle_id: com.example.myapp
///   package_name: com.example.myapp
/// ```
class ProjectConfig {
  final AppConfig app;
  final IosConfig? ios;
  final AndroidConfig? android;
  final Map<String, FlavorDef> flavors;
  final BrandingConfig? branding;
  final ScreenshotsConfig? screenshots;
  final SentryConfig? sentry;
  final FirebaseConfig? firebase;
  final AdmobConfig? admob;

  ProjectConfig({
    required this.app,
    this.ios,
    this.android,
    this.flavors = const {},
    this.branding,
    this.screenshots,
    this.sentry,
    this.firebase,
    this.admob,
  });

  /// Loads and parses an easy_setup.yaml file at [path].
  factory ProjectConfig.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw SetupException(
        'Configuration file not found: $path\n'
        'Run `easy_setup init` to create one.',
      );
    }
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw SetupException('Failed to parse $path:\n${e.message}');
    }
    if (doc is! Map) {
      throw SetupException('$path must contain a YAML map at the top level.');
    }
    return ProjectConfig.fromYaml(doc);
  }

  factory ProjectConfig.fromYaml(Map<dynamic, dynamic> yaml) {
    if (yaml.containsKey('easy_setup')) {
      throw SetupException(
        'This easy_setup.yaml uses the v1 schema (`easy_setup:` root key), '
        'which is no longer supported.\n'
        'v2 uses a new top-level schema (app / ios / android / flavors / ...).\n'
        'Run `easy_setup init --force` to generate a fresh v2 template.',
      );
    }
    final root = _mapOf(yaml, 'top level');
    if (!root.containsKey('app')) {
      throw SetupException("easy_setup.yaml: required section 'app' is missing.");
    }
    // Section presence is keyed on containsKey, not on a non-null value, so a
    // bare `android:` (which YAML parses to null) still enables the section
    // with its defaults.
    return ProjectConfig(
      app: AppConfig.fromYaml(_mapOf(root['app'], 'app')),
      ios: root.containsKey('ios')
          ? IosConfig.fromYaml(_mapOf(root['ios'], 'ios'))
          : null,
      android: root.containsKey('android')
          ? AndroidConfig.fromYaml(_mapOf(root['android'], 'android'))
          : null,
      flavors: _mapOf(root['flavors'], 'flavors').map(
        (name, node) =>
            MapEntry(name, FlavorDef.fromYaml(node, 'flavors.$name')),
      ),
      branding: root.containsKey('branding')
          ? BrandingConfig.fromYaml(_mapOf(root['branding'], 'branding'))
          : null,
      screenshots: root.containsKey('screenshots')
          ? ScreenshotsConfig.fromYaml(
              _mapOf(root['screenshots'], 'screenshots'))
          : null,
      sentry: root.containsKey('sentry')
          ? SentryConfig.fromYaml(_mapOf(root['sentry'], 'sentry'))
          : null,
      firebase: root.containsKey('firebase')
          ? FirebaseConfig.fromYaml(_mapOf(root['firebase'], 'firebase'))
          : null,
      admob: root.containsKey('admob')
          ? AdmobConfig.fromYaml(_mapOf(root['admob'], 'admob'))
          : null,
    );
  }
}

/// `app:` — required identity of the application.
class AppConfig {
  /// Display name of the app.
  final String name;

  /// iOS bundle identifier. Falls back to [packageName] when absent.
  final String bundleId;

  /// Android application ID. Falls back to [bundleId] when absent.
  final String packageName;

  AppConfig({
    required this.name,
    required this.bundleId,
    required this.packageName,
  });

  factory AppConfig.fromYaml(Map<String, Object?> yaml) {
    final name = _optionalString(yaml['name'], 'app.name');
    if (name == null) {
      throw SetupException("easy_setup.yaml: 'app.name' is required.");
    }
    final bundleId = _optionalString(yaml['bundle_id'], 'app.bundle_id');
    final packageName =
        _optionalString(yaml['package_name'], 'app.package_name');
    if (bundleId == null && packageName == null) {
      throw SetupException(
        "easy_setup.yaml: at least one of 'app.bundle_id' or "
        "'app.package_name' is required.",
      );
    }
    return AppConfig(
      name: name,
      bundleId: bundleId ?? packageName!,
      packageName: packageName ?? bundleId!,
    );
  }
}

/// A single iOS capability entry under `ios.capabilities`.
///
/// Entries are either a bare string (`- push_notifications`) or a
/// single-key map with parameters (`- app_groups: [group.com.example.app]`).
class IosCapability {
  final String name;
  final List<String> parameters;

  IosCapability(this.name, {this.parameters = const []});

  factory IosCapability.fromYaml(Object? node, String path) {
    if (node is String) return IosCapability(node);
    if (node is Map) {
      if (node.length != 1) {
        throw SetupException(
          "easy_setup.yaml: '$path' entries must be a capability name or a "
          'single-key map (e.g. `app_groups: [group.com.example.app]`).',
        );
      }
      final entry = node.entries.first;
      return IosCapability(
        entry.key.toString(),
        parameters: _stringListOf(entry.value, '$path.${entry.key}'),
      );
    }
    throw SetupException(
      "easy_setup.yaml: '$path' entries must be a string or a map.",
    );
  }
}

/// `ios:` — Apple developer account and native project settings.
class IosConfig {
  final String? teamId;
  final String? matchGitUrl;
  final List<IosCapability> capabilities;

  /// Info.plist `UIBackgroundModes` values (e.g. `audio`, `fetch`).
  final List<String> backgroundModes;

  IosConfig({
    this.teamId,
    this.matchGitUrl,
    this.capabilities = const [],
    this.backgroundModes = const [],
  });

  factory IosConfig.fromYaml(Map<String, Object?> yaml) {
    return IosConfig(
      teamId: _optionalString(yaml['team_id'], 'ios.team_id'),
      matchGitUrl: _optionalString(yaml['match_git_url'], 'ios.match_git_url'),
      capabilities: _listOf(yaml['capabilities'], 'ios.capabilities')
          .map((node) => IosCapability.fromYaml(node, 'ios.capabilities'))
          .toList(),
      backgroundModes:
          _stringListOf(yaml['background_modes'], 'ios.background_modes'),
    );
  }
}

/// `android:` — Google Play release settings.
class AndroidConfig {
  static const allowedTracks = ['internal', 'alpha', 'beta', 'production'];

  /// Default Play track for uploads (`internal` unless overridden).
  final String playTrackDefault;

  AndroidConfig({this.playTrackDefault = 'internal'});

  factory AndroidConfig.fromYaml(Map<String, Object?> yaml) {
    final track =
        _optionalString(yaml['play_track_default'], 'android.play_track_default') ??
            'internal';
    if (!allowedTracks.contains(track)) {
      throw SetupException(
        "easy_setup.yaml: 'android.play_track_default' must be one of "
        '${allowedTracks.join(' | ')} (got: $track).',
      );
    }
    return AndroidConfig(playTrackDefault: track);
  }
}

/// One entry under `flavors:` (e.g. `dev: { suffix: .dev, name: MyApp DEV }`).
class FlavorDef {
  /// Bundle ID / application ID suffix (e.g. `.dev`).
  final String? suffix;

  /// Display name override for this flavor.
  final String? name;

  FlavorDef({this.suffix, this.name});

  factory FlavorDef.fromYaml(Object? node, String path) {
    // `prod:` (null) and `prod: {}` both mean "no overrides".
    final map = _mapOf(node, path);
    return FlavorDef(
      suffix: _optionalString(map['suffix'], '$path.suffix'),
      name: _optionalString(map['name'], '$path.name'),
    );
  }
}

/// `branding:` — source assets for the icon pipeline.
class BrandingConfig {
  /// Directory holding icon.png (1024, no alpha) plus fg/bg/mono.png.
  final String iconSrc;

  BrandingConfig({required this.iconSrc});

  factory BrandingConfig.fromYaml(Map<String, Object?> yaml) {
    final iconSrc = _optionalString(yaml['icon_src'], 'branding.icon_src');
    if (iconSrc == null) {
      throw SetupException(
        "easy_setup.yaml: 'branding.icon_src' is required when the "
        "'branding' section is present.",
      );
    }
    return BrandingConfig(iconSrc: iconSrc);
  }
}

/// `screenshots:` — store screenshot pipeline settings.
class ScreenshotsConfig {
  static const allowedDevices = ['iphone_6_9', 'ipad_13', 'android_phone'];

  final List<String> locales;
  final List<String> devices;

  /// Path to the per-locale captions YAML for marketing composition.
  final String? captions;

  ScreenshotsConfig({
    this.locales = const [],
    this.devices = const [],
    this.captions,
  });

  factory ScreenshotsConfig.fromYaml(Map<String, Object?> yaml) {
    final devices = _stringListOf(yaml['devices'], 'screenshots.devices');
    for (final device in devices) {
      if (!allowedDevices.contains(device)) {
        throw SetupException(
          "easy_setup.yaml: unknown device '$device' in "
          "'screenshots.devices'. Allowed: ${allowedDevices.join(', ')}.",
        );
      }
    }
    return ScreenshotsConfig(
      locales: _stringListOf(yaml['locales'], 'screenshots.locales'),
      devices: devices,
      captions: _optionalString(yaml['captions'], 'screenshots.captions'),
    );
  }
}

/// `sentry:` — Sentry org/project for error monitoring provisioning.
class SentryConfig {
  final String org;

  /// Project slug. Defaults to a slug of the app name at setup time.
  final String? project;

  /// Team slug the project is created under. Defaults to the org's first
  /// team at setup time.
  final String? team;

  SentryConfig({required this.org, this.project, this.team});

  factory SentryConfig.fromYaml(Map<String, Object?> yaml) {
    final org = _optionalString(yaml['org'], 'sentry.org');
    if (org == null) {
      throw SetupException(
        "easy_setup.yaml: 'sentry.org' is required when the 'sentry' "
        'section is present.',
      );
    }
    return SentryConfig(
      org: org,
      project: _optionalString(yaml['project'], 'sentry.project'),
      team: _optionalString(yaml['team'], 'sentry.team'),
    );
  }
}

/// `firebase:` — Firebase project provisioning (GA4 = Firebase Analytics).
class FirebaseConfig {
  /// Firebase project ID. Created by `setup` when it does not exist yet.
  final String? projectId;

  /// Whether to link Google Analytics (GA4) to the project.
  final bool analytics;

  FirebaseConfig({this.projectId, this.analytics = false});

  factory FirebaseConfig.fromYaml(Map<String, Object?> yaml) {
    final analytics = yaml['analytics'] ?? false;
    if (analytics is! bool) {
      throw SetupException(
        "easy_setup.yaml: 'firebase.analytics' must be true or false.",
      );
    }
    return FirebaseConfig(
      projectId: _optionalString(yaml['project_id'], 'firebase.project_id'),
      analytics: analytics,
    );
  }
}

/// Per-platform ad unit IDs for one logical ad slot.
class AdUnitIds {
  static const allowedTypes = [
    'banner',
    'interstitial',
    'rewarded',
    'native',
    'app_open',
  ];

  final String? ios;
  final String? android;

  /// Ad format — when set, `setup` writes Google's official test ad unit ID
  /// of this format into env.json (debug) instead of the real ID.
  final String? type;

  AdUnitIds({this.ios, this.android, this.type});

  factory AdUnitIds.fromYaml(Object? node, String path) {
    final map = _mapOf(node, path);
    final type = _optionalString(map['type'], '$path.type');
    if (type != null && !allowedTypes.contains(type)) {
      throw SetupException(
        "easy_setup.yaml: '$path.type' must be one of "
        '${allowedTypes.join(' | ')} (got: $type).',
      );
    }
    return AdUnitIds(
      ios: _optionalString(map['ios'], '$path.ios'),
      android: _optionalString(map['android'], '$path.android'),
      type: type,
    );
  }
}

/// `admob:` — AdMob app IDs and ad units.
///
/// App IDs are entered manually (console-created) unless AdMob API access
/// has been approved — see V2_PLAN.md §5.4.
class AdmobConfig {
  final String? iosAppId;
  final String? androidAppId;
  final Map<String, AdUnitIds> adUnits;

  AdmobConfig({this.iosAppId, this.androidAppId, this.adUnits = const {}});

  factory AdmobConfig.fromYaml(Map<String, Object?> yaml) {
    return AdmobConfig(
      iosAppId: _optionalString(yaml['ios_app_id'], 'admob.ios_app_id'),
      androidAppId:
          _optionalString(yaml['android_app_id'], 'admob.android_app_id'),
      adUnits: _mapOf(yaml['ad_units'], 'admob.ad_units').map(
        (name, node) =>
            MapEntry(name, AdUnitIds.fromYaml(node, 'admob.ad_units.$name')),
      ),
    );
  }
}

// --- YAML node helpers -----------------------------------------------------

/// Normalizes [node] into a `Map<String, Object?>`.
/// `null` becomes an empty map so `section:` and `section: {}` are equivalent.
Map<String, Object?> _mapOf(Object? node, String path) {
  if (node == null) return {};
  if (node is Map) {
    return node.map((key, value) => MapEntry(key.toString(), value as Object?));
  }
  throw SetupException("easy_setup.yaml: '$path' must be a map.");
}

/// Normalizes [node] into a list. `null` becomes an empty list.
List<Object?> _listOf(Object? node, String path) {
  if (node == null) return const [];
  if (node is List) return List<Object?>.from(node);
  throw SetupException("easy_setup.yaml: '$path' must be a list.");
}

/// Normalizes [node] into a list of strings.
List<String> _stringListOf(Object? node, String path) =>
    _listOf(node, path).map((item) {
      if (item is String) return item;
      throw SetupException("easy_setup.yaml: '$path' must contain strings.");
    }).toList();

/// Returns [node] as a trimmed string, or null when absent/empty.
/// Numeric scalars are accepted and stringified.
String? _optionalString(Object? node, String path) {
  if (node == null) return null;
  if (node is String) {
    final trimmed = node.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (node is num) return node.toString();
  throw SetupException("easy_setup.yaml: '$path' must be a string.");
}
