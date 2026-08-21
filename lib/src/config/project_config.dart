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
  final BuildConfig? build;
  final SentryConfig? sentry;
  final AmplitudeConfig? amplitude;
  final FirebaseConfig? firebase;
  final AdmobConfig? admob;
  final SiteConfig? site;

  ProjectConfig({
    required this.app,
    this.ios,
    this.android,
    this.flavors = const {},
    this.branding,
    this.screenshots,
    this.build,
    this.sentry,
    this.amplitude,
    this.firebase,
    this.admob,
    this.site,
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
      throw SetupException(
        "easy_setup.yaml: required section 'app' is missing.",
      );
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
              _mapOf(root['screenshots'], 'screenshots'),
            )
          : null,
      build: root.containsKey('build')
          ? BuildConfig.fromYaml(_mapOf(root['build'], 'build'))
          : null,
      sentry: root.containsKey('sentry')
          ? SentryConfig.fromYaml(_mapOf(root['sentry'], 'sentry'))
          : null,
      amplitude: root.containsKey('amplitude')
          ? AmplitudeConfig.fromYaml(_mapOf(root['amplitude'], 'amplitude'))
          : null,
      firebase: root.containsKey('firebase')
          ? FirebaseConfig.fromYaml(_mapOf(root['firebase'], 'firebase'))
          : null,
      admob: root.containsKey('admob')
          ? AdmobConfig.fromYaml(_mapOf(root['admob'], 'admob'))
          : null,
      site: root.containsKey('site')
          ? SiteConfig.fromYaml(_mapOf(root['site'], 'site'))
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
    final packageName = _optionalString(
      yaml['package_name'],
      'app.package_name',
    );
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
      backgroundModes: _stringListOf(
        yaml['background_modes'],
        'ios.background_modes',
      ),
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
        _optionalString(
          yaml['play_track_default'],
          'android.play_track_default',
        ) ??
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
  static const allowedDevices = [
    'iphone_6_5',
    'iphone_6_9',
    'ipad_13',
    'android_phone',
  ];

  final List<String> locales;
  final List<String> devices;

  ScreenshotsConfig({this.locales = const [], this.devices = const []});

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
    if (yaml.containsKey('captions')) {
      throw SetupException(
        "easy_setup.yaml: 'screenshots.captions' is no longer used. The "
        'screenshot copy, palettes and fonts now live in '
        'assets/store/screenshots/screenshots.yaml, next to the '
        'template.html that renders them. Remove the key and re-run '
        '`easy_setup setup --only screenshots` to generate both files.',
      );
    }
    return ScreenshotsConfig(
      locales: _stringListOf(yaml['locales'], 'screenshots.locales'),
      devices: devices,
    );
  }
}

/// `build:` — how release builds are produced.
///
/// The Setup Kit writes the DSN, the analytics key and the ad unit IDs into
/// `env.json` / `env.prod.json`; without `--dart-define-from-file` a release
/// build compiles them as empty strings, so the SDKs silently do nothing.
/// Deploy passes the file named here.
class BuildConfig {
  /// Env file release builds compile with. Defaults to `env.prod.json` when
  /// that file exists.
  static const defaultDartDefineFile = 'env.prod.json';

  final String? dartDefineFile;

  BuildConfig({this.dartDefineFile});

  factory BuildConfig.fromYaml(Map<String, Object?> yaml) => BuildConfig(
    dartDefineFile: _optionalString(
      yaml['dart_define_file'],
      'build.dart_define_file',
    ),
  );
}

/// `sentry:` — Sentry org/project for error monitoring provisioning.
class SentryConfig {
  final String org;

  /// Project slug. Defaults to a slug of the app name at setup time.
  final String? project;

  /// Team slug the project is created under. Defaults to the org's first
  /// team at setup time.
  final String? team;

  /// Whether `setup` adds the `sentry_flutter` dependency to pubspec.yaml.
  final bool sdk;

  /// Whether `setup` wires debug-symbol upload: the `sentry_dart_plugin`
  /// dev dependency plus the `sentry:` block it reads from pubspec.yaml.
  final bool uploadSymbols;

  SentryConfig({
    required this.org,
    this.project,
    this.team,
    this.sdk = true,
    this.uploadSymbols = true,
  });

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
      sdk: _boolOf(yaml['sdk'], 'sentry.sdk', orElse: true),
      uploadSymbols: _boolOf(
        yaml['upload_symbols'],
        'sentry.upload_symbols',
        orElse: true,
      ),
    );
  }
}

/// `amplitude:` — Amplitude product analytics wiring.
///
/// Amplitude issues one API key per project and has no public
/// project-creation API (only ingestion, query, Experiment and SCIM APIs
/// exist), so the project itself is created once in the console. Everything
/// after that runs from here: the key arrives through an environment
/// variable, `setup` verifies it against the ingestion API and writes it
/// into the dart-define env files — it is never pasted into a tracked file
/// by hand.
class AmplitudeConfig {
  static const allowedRegions = ['us', 'eu'];

  /// Env var carrying the production project's API key.
  static const defaultApiKeyEnv = 'AMPLITUDE_API_KEY';

  /// Env var carrying the development project's API key (optional — when
  /// unset, debug builds get an empty key, which makes the SDK a no-op).
  static const defaultDevApiKeyEnv = 'AMPLITUDE_DEV_API_KEY';

  /// The dart-define key the app reads with `String.fromEnvironment`.
  static const envKey = 'AMPLITUDE_API_KEY';

  /// Amplitude project name. Used in log and error messages only.
  final String? project;

  final String apiKeyEnv;
  final String devApiKeyEnv;

  /// Data residency: `us` (default) or `eu` — decides the ingestion host.
  final String region;

  /// Whether to verify the key against the ingestion API before writing it.
  final bool verify;

  /// Whether `setup` adds the `amplitude_flutter` dependency.
  final bool sdk;

  AmplitudeConfig({
    this.project,
    this.apiKeyEnv = defaultApiKeyEnv,
    this.devApiKeyEnv = defaultDevApiKeyEnv,
    this.region = 'us',
    this.verify = true,
    this.sdk = true,
  });

  /// Ingestion endpoint for [region] — also used as the key-verification
  /// probe target.
  String get ingestionUrl => region == 'eu'
      ? 'https://api.eu.amplitude.com/2/httpapi'
      : 'https://api2.amplitude.com/2/httpapi';

  factory AmplitudeConfig.fromYaml(Map<String, Object?> yaml) {
    final region =
        _optionalString(yaml['region'], 'amplitude.region')?.toLowerCase() ??
        'us';
    if (!allowedRegions.contains(region)) {
      throw SetupException(
        "easy_setup.yaml: 'amplitude.region' must be one of "
        '${allowedRegions.join(' | ')} (got: $region).',
      );
    }
    return AmplitudeConfig(
      project: _optionalString(yaml['project'], 'amplitude.project'),
      apiKeyEnv:
          _optionalString(yaml['api_key_env'], 'amplitude.api_key_env') ??
          defaultApiKeyEnv,
      devApiKeyEnv:
          _optionalString(
            yaml['dev_api_key_env'],
            'amplitude.dev_api_key_env',
          ) ??
          defaultDevApiKeyEnv,
      region: region,
      verify: _boolOf(yaml['verify'], 'amplitude.verify', orElse: true),
      sdk: _boolOf(yaml['sdk'], 'amplitude.sdk', orElse: true),
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

  factory FirebaseConfig.fromYaml(Map<String, Object?> yaml) => FirebaseConfig(
    projectId: _optionalString(yaml['project_id'], 'firebase.project_id'),
    analytics: _boolOf(yaml['analytics'], 'firebase.analytics', orElse: false),
  );
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
  /// of this format into env.json (debug) instead of the real ID. It is also
  /// what the AdMob API needs to create the unit.
  final String? type;

  /// Name the unit carries in AdMob. Defaults to the yaml key, and is what
  /// API lookups match on — renaming it in the console breaks the match.
  final String? displayName;

  AdUnitIds({this.ios, this.android, this.type, this.displayName});

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
      displayName: _optionalString(map['display_name'], '$path.display_name'),
    );
  }
}

/// `admob:` — AdMob app IDs and ad units.
///
/// IDs left out of the yaml are looked up through the AdMob API (and created
/// there when the account has creation access) — see V2_PLAN.md §5.4.
class AdmobConfig {
  final String? iosAppId;
  final String? androidAppId;
  final Map<String, AdUnitIds> adUnits;

  /// AdMob publisher account (`pub-…`). Discovered via the API when absent.
  final String? publisherId;

  /// Whether missing IDs may be resolved through the AdMob API. Turn it off
  /// to keep `setup` offline and declare every ID in the yaml.
  final bool auto;

  AdmobConfig({
    this.iosAppId,
    this.androidAppId,
    this.adUnits = const {},
    this.publisherId,
    this.auto = true,
  });

  factory AdmobConfig.fromYaml(Map<String, Object?> yaml) {
    final publisherId = _optionalString(
      yaml['publisher_id'],
      'admob.publisher_id',
    );
    if (publisherId != null && !publisherId.startsWith('pub-')) {
      throw SetupException(
        "easy_setup.yaml: 'admob.publisher_id' must look like "
        'pub-1234567890123456 (got: $publisherId).',
      );
    }
    return AdmobConfig(
      iosAppId: _optionalString(yaml['ios_app_id'], 'admob.ios_app_id'),
      androidAppId: _optionalString(
        yaml['android_app_id'],
        'admob.android_app_id',
      ),
      adUnits: _mapOf(yaml['ad_units'], 'admob.ad_units').map(
        (name, node) => MapEntry(
          _adUnitName(name),
          AdUnitIds.fromYaml(node, 'admob.ad_units.$name'),
        ),
      ),
      publisherId: publisherId,
      auto: _boolOf(yaml['auto'], 'admob.auto', orElse: true),
    );
  }
}

/// `site:` — the promo/support/privacy site every store listing needs.
/// Most fields fall back to easy_setup_store_info.yaml, so an empty
/// `site:` is a valid way to opt in.
class SiteConfig {
  /// Published base URL. Derived from the GitHub remote when absent.
  final String? baseUrl;

  /// Locale of the generated pages (default: the first store locale).
  final String? locale;

  /// One-line pitch. Falls back to the store subtitle.
  final String? tagline;

  /// Bullet points for the landing page.
  final List<String> features;

  /// Design direction handed to the AI skill (e.g. "warm, retro LCD").
  final String? mood;

  final String? contactEmail;
  final String? appStoreUrl;
  final String? playStoreUrl;
  final String? privacyEffectiveDate;

  SiteConfig({
    this.baseUrl,
    this.locale,
    this.tagline,
    this.features = const [],
    this.mood,
    this.contactEmail,
    this.appStoreUrl,
    this.playStoreUrl,
    this.privacyEffectiveDate,
  });

  factory SiteConfig.fromYaml(Map<String, Object?> yaml) => SiteConfig(
    baseUrl: _optionalString(yaml['base_url'], 'site.base_url'),
    locale: _optionalString(yaml['locale'], 'site.locale'),
    tagline: _optionalString(yaml['tagline'], 'site.tagline'),
    features: _stringListOf(yaml['features'], 'site.features'),
    mood: _optionalString(yaml['mood'], 'site.mood'),
    contactEmail: _optionalString(yaml['contact_email'], 'site.contact_email'),
    appStoreUrl: _optionalString(yaml['app_store_url'], 'site.app_store_url'),
    playStoreUrl: _optionalString(
      yaml['play_store_url'],
      'site.play_store_url',
    ),
    privacyEffectiveDate: _optionalString(
      yaml['privacy_effective_date'],
      'site.privacy_effective_date',
    ),
  );
}

/// Dart words that cannot be an identifier, so cannot be an accessor name.
const _dartReservedWords = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

/// Whether [name] can be an ad unit key: `_adUnitName` throws on anything
/// else, so `--adopt` has to refuse the same names rather than write a file
/// that will not parse on the next run.
///
/// An ad unit name has to survive two translations: into an environment key
/// (`ADMOB_BANNER_MAIN_IOS`) and into a Dart accessor (`bannerMain`) in the
/// generated `lib/ads/ad_ids.dart`. lower_snake_case is what makes both
/// unambiguous — and it keeps the camelCase mapping injective, so two names
/// can never collide on one accessor.
bool isUsableAdUnitName(String name) =>
    RegExp(r'^[a-z][a-z0-9]*(_[a-z0-9]+)*$').hasMatch(name) &&
    !_dartReservedWords.contains(name);

String _adUnitName(String name) {
  if (!RegExp(r'^[a-z][a-z0-9]*(_[a-z0-9]+)*$').hasMatch(name)) {
    throw SetupException(
      "easy_setup.yaml: 'admob.ad_units.$name' is not a usable name. Use "
      'lower_snake_case starting with a letter — banner_main, '
      'rewarded_hint, app_open — since the name becomes both the '
      'ADMOB_… environment key and a Dart accessor.',
    );
  }
  if (_dartReservedWords.contains(name)) {
    throw SetupException(
      "easy_setup.yaml: 'admob.ad_units.$name' is a Dart reserved word, so "
      'it cannot become an accessor in lib/ads/ad_ids.dart. Rename it — '
      '${name}_ad, for instance.',
    );
  }
  return name;
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

/// Returns [node] as a bool, or [orElse] when the key is absent.
bool _boolOf(Object? node, String path, {required bool orElse}) {
  if (node == null) return orElse;
  if (node is bool) return node;
  throw SetupException("easy_setup.yaml: '$path' must be true or false.");
}

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
