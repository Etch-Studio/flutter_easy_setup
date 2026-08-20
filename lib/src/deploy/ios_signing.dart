/// The match profile types easy_setup drives, and how each one is applied to
/// the Xcode project.
///
/// One deliberate detail: the profile names match creates are
/// `match Development …`, `match AdHoc …`, `match AppStore …`. The middle word
/// is not `type.capitalize` — "adhoc" would give "Adhoc" — so the label is
/// spelled out here instead of derived.
enum MatchProfile {
  development(
    matchType: 'development',
    label: 'Development',
    identity: 'Apple Development',
    // Release included on purpose: `flutter run --release` then installs on a
    // device like the other two modes. `deploy` switches Release to the App
    // Store profile for the duration of its build and restores it afterwards.
    configurations: ['Debug', 'Profile', 'Release'],
    appliesByDefault: true,
  ),
  adhoc(
    matchType: 'adhoc',
    label: 'AdHoc',
    identity: 'Apple Distribution',
    configurations: ['Release'],
    // A distribution profile cannot install on a device, so writing it into
    // the project would break `flutter run` — ask for it explicitly.
    appliesByDefault: false,
  ),
  appstore(
    matchType: 'appstore',
    label: 'AppStore',
    identity: 'Apple Distribution',
    configurations: ['Release'],
    appliesByDefault: false,
  );

  const MatchProfile({
    required this.matchType,
    required this.label,
    required this.identity,
    required this.configurations,
    required this.appliesByDefault,
  });

  /// `match <type>` argument.
  final String matchType;

  /// Middle word of the profile name match generates.
  final String label;

  /// Xcode's CODE_SIGN_IDENTITY for this kind of profile.
  final String identity;

  /// Build configurations this profile belongs to.
  final List<String> configurations;

  /// Whether `certs` writes it into the project without being asked.
  final bool appliesByDefault;

  static MatchProfile byName(String name) => values.firstWhere(
        (profile) => profile.matchType == name,
        orElse: () => throw ArgumentError.value(name, 'name'),
      );

  static List<String> get names =>
      values.map((profile) => profile.matchType).toList();

  /// Name match gives the profile for [bundleId].
  String profileName(String bundleId) => 'match $label $bundleId';
}

/// Builds the fastlane invocations for certificates and profiles, shared by
/// `deploy` and `certs` so the two can never drift apart.
abstract final class IosSigning {
  static const xcodeProjectPath = 'ios/Runner.xcodeproj';

  /// `fastlane match <type> …` — fetches the certificate and profile, and
  /// creates them when [readonly] is false.
  static List<String> matchArguments({
    required MatchProfile profile,
    required String bundleId,
    required String gitUrl,
    required String teamId,
    required String apiKeyPath,
    required bool readonly,
  }) =>
      [
        'match',
        profile.matchType,
        '--app_identifier',
        bundleId,
        '--git_url',
        gitUrl,
        '--team_id',
        teamId,
        '--api_key_path',
        apiKeyPath,
        '--readonly',
        '$readonly',
        // Regenerate when a device was registered since the stored profile was
        // created; ignored for appstore profiles. Without it match hands back
        // the old profile and the new device is missing from it.
        '--force_for_new_devices',
        'true',
      ];

  /// `fastlane run update_code_signing_settings …` — points the Xcode project
  /// at the profile match just produced.
  ///
  /// ExportOptions.plist alone only covers the export step; the archive step
  /// reads the project's own signing settings, which is why this exists.
  static List<String> signingArguments({
    required MatchProfile profile,
    required String bundleId,
    required String teamId,
  }) =>
      [
        'run',
        'update_code_signing_settings',
        'use_automatic_signing:false',
        'path:$xcodeProjectPath',
        'build_configurations:${profile.configurations.join(',')}',
        'team_id:$teamId',
        'code_sign_identity:${profile.identity}',
        'bundle_identifier:$bundleId',
        'profile_name:${profile.profileName(bundleId)}',
      ];

  /// `fastlane run register_device …` — a device has to be on the portal
  /// before a development or ad-hoc profile can include it.
  static List<String> registerDeviceArguments({
    required String udid,
    required String name,
    required String teamId,
    required String apiKeyPath,
  }) =>
      [
        'run',
        'register_device',
        'udid:$udid',
        'name:$name',
        'team_id:$teamId',
        'api_key_path:$apiKeyPath',
      ];
}
