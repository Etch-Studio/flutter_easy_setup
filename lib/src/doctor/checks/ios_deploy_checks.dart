import 'dart:io';

import '../check.dart';

/// Env var names for the App Store Connect API key (matches the GitHub
/// organization secret names in V2_PLAN.md §6.3).
abstract final class AscEnv {
  static const keyId = 'ASC_KEY_ID';
  static const issuerId = 'ASC_ISSUER_ID';

  /// Raw .p8 contents (used in CI secrets).
  static const keyP8 = 'ASC_KEY_P8';

  /// Path to the .p8 file (more convenient locally).
  static const keyP8Path = 'ASC_KEY_P8_PATH';

  /// Whether the key id, issuer id, and a p8 source are all present.
  static bool isComplete(Map<String, String> env) =>
      !_blank(env[keyId]) &&
      !_blank(env[issuerId]) &&
      (!_blank(env[keyP8]) || !_blank(env[keyP8Path]));

  /// Resolves the .p8 private key PEM from the environment (raw contents
  /// win over the file path), or null when neither source is set.
  static String? resolveKey(Map<String, String> env) {
    final raw = env[keyP8];
    if (!_blank(raw)) return raw;
    final path = env[keyP8Path];
    if (_blank(path)) return null;
    final file = File(path!);
    if (!file.existsSync()) return null;
    return file.readAsStringSync();
  }
}

/// Base for checks that only apply when the `ios:` section is configured.
abstract class _IosDeployCheck extends DoctorCheck {
  @override
  String get category => DoctorCategory.iosDeploy;

  String get title;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final config = context.config;
    if (config == null) {
      return CheckResult.skipped(title, detail: 'no valid easy_setup.yaml');
    }
    if (config.ios == null) {
      return CheckResult.skipped(title, detail: "'ios' section not configured");
    }
    return check(context);
  }

  Future<CheckResult> check(DoctorContext context);
}

/// Verifies the App Store Connect API key is available via env vars.
class AscApiKeyCheck extends _IosDeployCheck {
  @override
  String get title => 'App Store Connect API key';

  static const _issueFix = '''
1. App Store Connect > Users and Access > Integrations > App Store Connect API
2. Generate an API key with the "App Manager" role and download the .p8 file
3. Export the environment variables:
     export ASC_KEY_ID=<Key ID>
     export ASC_ISSUER_ID=<Issuer ID>
     export ASC_KEY_P8_PATH=<path to the downloaded .p8>
   (CI uses the ASC_KEY_P8 secret with the raw .p8 contents instead.)''';

  @override
  Future<CheckResult> check(DoctorContext context) async {
    final env = context.env;
    final missing = <String>[
      if (_blank(env[AscEnv.keyId])) AscEnv.keyId,
      if (_blank(env[AscEnv.issuerId])) AscEnv.issuerId,
      if (_blank(env[AscEnv.keyP8]) && _blank(env[AscEnv.keyP8Path]))
        '${AscEnv.keyP8} or ${AscEnv.keyP8Path}',
    ];
    if (missing.isNotEmpty) {
      return CheckResult.error(
        title,
        detail: 'missing env: ${missing.join(', ')}',
        fix: _issueFix,
      );
    }
    // The path only matters when raw contents are not provided — a valid
    // ASC_KEY_P8 makes a stale ASC_KEY_P8_PATH harmless.
    final p8Path = env[AscEnv.keyP8Path];
    if (_blank(env[AscEnv.keyP8]) &&
        !_blank(p8Path) &&
        !File(p8Path!).existsSync()) {
      return CheckResult.error(
        title,
        detail: '${AscEnv.keyP8Path} points to a missing file: $p8Path',
        fix: _issueFix,
      );
    }
    return CheckResult.ok(title, detail: 'key ${env[AscEnv.keyId]}');
  }
}

/// Verifies `ios.team_id` is present and looks like an Apple Team ID.
class TeamIdCheck extends _IosDeployCheck {
  static final _teamIdPattern = RegExp(r'^[A-Z0-9]{10}$');

  @override
  String get title => 'Apple Team ID';

  @override
  Future<CheckResult> check(DoctorContext context) async {
    final teamId = context.config!.ios!.teamId;
    if (teamId == null) {
      return const CheckResult.warning(
        'Apple Team ID',
        detail: "'ios.team_id' not set",
        fix: 'Find it at developer.apple.com > Account > Membership details, '
            'then set ios.team_id in easy_setup.yaml.',
      );
    }
    if (!_teamIdPattern.hasMatch(teamId)) {
      return CheckResult.warning(
        'Apple Team ID',
        detail: "'$teamId' does not look like a Team ID "
            '(expected 10 characters, A-Z/0-9)',
      );
    }
    return CheckResult.ok('Apple Team ID', detail: teamId);
  }
}

/// Verifies the fastlane match storage repo and password are configured.
class MatchCheck extends _IosDeployCheck {
  static const _matchPasswordEnv = 'MATCH_PASSWORD';

  @override
  String get title => 'Code signing (match)';

  @override
  Future<CheckResult> check(DoctorContext context) async {
    final matchGitUrl = context.config!.ios!.matchGitUrl;
    if (matchGitUrl == null) {
      return const CheckResult.warning(
        'Code signing (match)',
        detail: "'ios.match_git_url' not set",
        fix: 'Create a private git repo for certificates/profiles and set '
            'ios.match_git_url in easy_setup.yaml.',
      );
    }
    if (_blank(context.env[_matchPasswordEnv])) {
      return const CheckResult.error(
        'Code signing (match)',
        detail: 'missing env: $_matchPasswordEnv',
        fix: 'Export MATCH_PASSWORD — the passphrase used to encrypt the '
            'match certificates repo.',
      );
    }
    return CheckResult.ok('Code signing (match)', detail: matchGitUrl);
  }
}

bool _blank(String? value) => value == null || value.trim().isEmpty;
