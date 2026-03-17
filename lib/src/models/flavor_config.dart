import 'dart:io';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';
import 'ci_cd_config.dart' show LocaleMetadataConfig;

/// Model class that holds Android signing configuration.
class SigningConfig {
  final String keystore;
  final String alias;

  const SigningConfig({required this.keystore, required this.alias});

  factory SigningConfig.fromYaml(Map yaml) {
    return SigningConfig(
      keystore: yaml['keystore'] as String,
      alias: yaml['alias'] as String,
    );
  }
}

/// Model class that holds Firebase configuration.
///
/// [projectId]: Firebase project ID used by FlutterFire CLI to download config files.
class FirebaseConfig {
  final String projectId;

  const FirebaseConfig({required this.projectId});

  factory FirebaseConfig.fromYaml(Map yaml) {
    final projectId = yaml['project_id'] as String?;
    if (projectId == null) {
      throw ArgumentError('firebase.project_id is required');
    }
    return FirebaseConfig(projectId: projectId);
  }
}

/// Model class that holds additional per-flavor iOS configuration.
class IosFlavorConfig {
  final String? teamId;
  final String? provisioningProfile;
  final String? codeSignIdentity;
  final String? entitlements;

  const IosFlavorConfig({
    this.teamId,
    this.provisioningProfile,
    this.codeSignIdentity,
    this.entitlements,
  });

  factory IosFlavorConfig.fromYaml(Map yaml) {
    return IosFlavorConfig(
      teamId: yaml['team_id'] as String?,
      provisioningProfile: yaml['provisioning_profile'] as String?,
      codeSignIdentity: yaml['code_sign_identity'] as String?,
      entitlements: yaml['entitlements'] as String?,
    );
  }
}

/// Model class that holds per-flavor locale configuration.
///
/// [appName]: The app display name for the locale
class FlavorLocalizedConfig {
  final String? appName;

  const FlavorLocalizedConfig({this.appName});

  factory FlavorLocalizedConfig.fromYaml(Map yaml) {
    return FlavorLocalizedConfig(
      appName: yaml['app_name'] as String?,
    );
  }
}

/// Model class that holds configuration values for a single flavor.
///
/// [bundleId]: The app's unique identifier (e.g., com.example.app.dev)
/// [name]: The user-facing app display name (e.g., MyApp Dev)
class FlavorConfig {
  final String bundleId;
  final String name;
  final int? versionCode;
  final String? versionName;
  final SigningConfig? signing;
  final FirebaseConfig? firebase;
  final IosFlavorConfig? ios;
  final String? appIcon;
  final Map<String, FlavorLocalizedConfig>? localized;

  const FlavorConfig({
    required this.bundleId,
    required this.name,
    this.versionCode,
    this.versionName,
    this.signing,
    this.firebase,
    this.ios,
    this.appIcon,
    this.localized,
  });

  /// Creates a FlavorConfig instance from a YAML map.
  factory FlavorConfig.fromYaml(Map yaml) {
    Map<String, FlavorLocalizedConfig>? localized;
    final localizedMap = yaml['localized'];
    if (localizedMap != null) {
      localized = <String, FlavorLocalizedConfig>{};
      for (final entry in (localizedMap as Map).entries) {
        localized[entry.key as String] =
            FlavorLocalizedConfig.fromYaml(entry.value as Map);
      }
    }

    return FlavorConfig(
      bundleId: yaml['bundle_id'] as String,
      name: yaml['name'] as String,
      versionCode: yaml['version_code'] as int?,
      versionName: yaml['version_name'] as String?,
      signing: yaml['signing'] != null
          ? SigningConfig.fromYaml(yaml['signing'] as Map)
          : null,
      firebase: yaml['firebase'] != null
          ? FirebaseConfig.fromYaml(yaml['firebase'] as Map)
          : null,
      ios: yaml['ios'] != null
          ? IosFlavorConfig.fromYaml(yaml['ios'] as Map)
          : null,
      appIcon: yaml['app_icon'] as String?,
      localized: localized,
    );
  }
}

/// Class that holds the parsed result of the entire easy_setup.yaml file.
///
/// [flavors]: A map with flavor names (dev, prod, etc.) as keys and [FlavorConfig] as values
/// [localizations]: Optional -- list of languages to register in Xcode knownRegions
/// [permission]: Optional -- default iOS permission descriptions (for Base.lproj)
/// [localizedPermission]: Optional -- per-locale iOS permission descriptions
/// [metadata]: Optional -- App Store Connect metadata (per-locale)
class EasySetupConfig {
  final Map<String, FlavorConfig> flavors;
  final String? iosVersion;
  final List<String>? localizations;
  final Map<String, String>? permission;
  final Map<String, Map<String, String>>? localizedPermission;
  final Map<String, LocaleMetadataConfig>? metadata;

  const EasySetupConfig({
    required this.flavors,
    this.iosVersion,
    this.localizations,
    this.permission,
    this.localizedPermission,
    this.metadata,
  });

  /// Reads and parses the easy_setup.yaml file located at [path].
  ///
  /// Throws a [SetupException] with a usage example if the file is not found.
  /// Also throws a [SetupException] on YAML syntax errors.
  factory EasySetupConfig.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw SetupException(
        'easy_setup.yaml not found at $path\n'
        'Create it with:\n'
        'easy_setup:\n'
        '  flavors:\n'
        '    dev:\n'
        '      bundle_id: com.example.app.dev\n'
        '      name: MyApp Dev',
      );
    }
    try {
      final doc = loadYaml(file.readAsStringSync()) as Map;
      final easySetup = doc['easy_setup'];
      if (easySetup == null || easySetup is! Map) {
        throw SetupException(
          'Missing "easy_setup" key in easy_setup.yaml.\n'
          'Expected structure:\n'
          'easy_setup:\n'
          '  flavors:\n'
          '    dev:\n'
          '      bundle_id: com.example.app.dev\n'
          '      name: MyApp Dev',
        );
      }
      final flavorsMap = easySetup['flavors'] as Map;
      final flavors = <String, FlavorConfig>{};
      for (final entry in flavorsMap.entries) {
        flavors[entry.key as String] = FlavorConfig.fromYaml(entry.value as Map);
      }

      // Parse localizations list
      List<String>? localizations;
      final locList = easySetup['localizations'];
      if (locList != null) {
        localizations = (locList as List).map((e) => e as String).toList();
      }

      // Parse default permission map
      Map<String, String>? permission;
      final permMap = easySetup['permission'];
      if (permMap != null) {
        permission = <String, String>{};
        for (final entry in (permMap as Map).entries) {
          permission[entry.key as String] = entry.value as String;
        }
      }

      // Parse per-locale permission map
      Map<String, Map<String, String>>? localizedPermission;
      final locPermMap = easySetup['localized_permission'];
      if (locPermMap != null) {
        localizedPermission = <String, Map<String, String>>{};
        for (final entry in (locPermMap as Map).entries) {
          final localePerms = <String, String>{};
          for (final permEntry in (entry.value as Map).entries) {
            localePerms[permEntry.key as String] = permEntry.value as String;
          }
          localizedPermission[entry.key as String] = localePerms;
        }
      }

      Map<String, LocaleMetadataConfig>? metadata;
      final metadataMap = easySetup['metadata'];
      if (metadataMap != null) {
        metadata = <String, LocaleMetadataConfig>{};
        for (final entry in (metadataMap as Map).entries) {
          metadata[entry.key as String] =
              LocaleMetadataConfig.fromYaml(entry.value as Map);
        }
      }

      // Parse ios_version
      final iosVersion = easySetup['ios_version']?.toString();

      return EasySetupConfig(
        flavors: flavors,
        iosVersion: iosVersion,
        localizations: localizations,
        permission: permission,
        localizedPermission: localizedPermission,
        metadata: metadata,
      );
    } catch (e) {
      if (e is SetupException) rethrow;
      throw SetupException('Failed to parse easy_setup.yaml: $e');
    }
  }
}
