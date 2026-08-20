import 'dart:io';

import '../appstore/asc_api_client.dart';
import '../appstore/asc_api_key_file.dart';
import '../appstore/asc_jwt.dart';
import '../config/project_config.dart';
import '../deploy/deploy_steps.dart';
import '../deploy/ios_signing.dart';
import '../doctor/checks/ios_deploy_checks.dart';
import '../exceptions.dart';
import '../utils/http_json_client.dart';
import '../utils/process_runner.dart';
import '../utils/project_finder.dart';

/// `easy_setup certs` — the iOS signing assets a *local* build needs.
///
/// `deploy` already syncs the App Store profile on every run, but a device
/// install cannot use a distribution profile, so a development one has to
/// exist too. This command creates it (and the ad-hoc one when asked) through
/// the same match repository, and points the Xcode project at it — the two
/// halves that otherwise get done by hand.
class CertsCommand {
  static Future<int> run({
    String? projectRoot,
    bool dryRun = false,
    String type = 'development',
    bool readonly = false,
    bool? apply,
    String? registerDeviceUdid,
    String? deviceName,
    bool listDevices = false,
    Map<String, String>? env,
    ProcessRunner processes = const ProcessRunner(),
    HttpJsonClient? http,
    StringSink? out,
  }) async {
    final MatchProfile profile;
    try {
      profile = MatchProfile.byName(type);
    } on ArgumentError {
      throw SetupException(
        "Unknown --type '$type' — expected ${MatchProfile.names.join(' | ')}.",
      );
    }

    final root = ProjectFinder.findFlutterRoot(projectRoot);
    if (root == null) {
      throw SetupException(
        'Could not find a Flutter project root. '
        'Run inside a Flutter project, or pass --project-root <path>.',
      );
    }
    final config = ProjectConfig.fromFile(ProjectFinder.configPath(root));
    final environment = env ?? Platform.environment;
    final sink = out ?? stdout;

    final ios = config.ios;
    if (ios?.teamId == null || ios?.matchGitUrl == null) {
      throw SetupException(
        'certs needs the ios section of easy_setup.yaml:\n'
        '  ios:\n'
        '    team_id: ABCDE12345          # Apple Developer team\n'
        '    match_git_url: git@github.com:org/certificates.git',
      );
    }
    _requireAscKey(environment);

    if (listDevices) {
      await _listDevices(
        env: environment,
        http: http ?? IoHttpJsonClient(),
        out: sink,
        dryRun: dryRun,
        highlight: registerDeviceUdid,
      );
      // Listing is a question, not a change — answer it and stop.
      if (registerDeviceUdid == null) return 0;
    }

    final runner = _CertsRunner(
      projectRoot: root,
      processes: processes,
      dryRun: dryRun,
      out: sink,
    );

    sink.writeln('Syncing ${profile.matchType} signing for '
        '${config.app.bundleId} (team ${ios!.teamId})');

    final workDir = dryRun
        ? null
        : Directory.systemTemp.createTempSync('easy_setup_certs');
    try {
      final apiKeyPath =
          dryRun ? '<api_key.json>' : writeAscApiKeyJson(workDir!, environment);

      if (registerDeviceUdid != null) {
        await runner.step(
          'fastlane register_device',
          'fastlane',
          IosSigning.registerDeviceArguments(
            udid: registerDeviceUdid,
            name: deviceName ?? 'Device $registerDeviceUdid',
            teamId: ios.teamId!,
            apiKeyPath: apiKeyPath,
          ),
        );
      }

      await runner.step(
        'fastlane match ${profile.matchType}',
        'fastlane',
        IosSigning.matchArguments(
          profile: profile,
          bundleId: config.app.bundleId,
          gitUrl: ios.matchGitUrl!,
          teamId: ios.teamId!,
          apiKeyPath: apiKeyPath,
          readonly: readonly,
        ),
      );

      if (apply ?? profile.appliesByDefault) {
        await runner.step(
          'fastlane update_code_signing_settings',
          'fastlane',
          IosSigning.signingArguments(
            profile: profile,
            bundleId: config.app.bundleId,
            teamId: ios.teamId!,
          ),
        );
        sink.writeln('\n✓ ${profile.configurations.join('/')} now sign with '
            '"${profile.profileName(config.app.bundleId)}"');
        if (profile == MatchProfile.development) {
          sink.writeln('  → Run on a device: flutter run --release'
              '${_defineHint(root)}');
          sink.writeln('  → `deploy` switches Release to the App Store profile '
              'while it builds, then restores it');
        }
      } else {
        sink.writeln('\n✓ ${profile.matchType} profile synced: '
            '"${profile.profileName(config.app.bundleId)}"');
        sink.writeln('  Xcode project untouched — pass --apply to write it '
            '(${profile.configurations.join('/')} would change).');
      }
    } finally {
      workDir?.deleteSync(recursive: true);
    }

    if (dryRun) {
      sink.writeln('\n[dry-run] Preview complete — nothing was created or '
          'written.');
    }
    return 0;
  }

  /// Prints the portal's device list — a development profile only covers what
  /// is on it, so this answers "why is my phone not in the profile?".
  static Future<void> _listDevices({
    required Map<String, String> env,
    required HttpJsonClient http,
    required StringSink out,
    required bool dryRun,
    String? highlight,
  }) async {
    if (dryRun) {
      out.writeln('\n[dry-run] Would list the registered devices');
      return;
    }
    final rawKey = env[AscEnv.keyP8];
    final privateKey = (rawKey != null && rawKey.trim().isNotEmpty)
        ? rawKey
        : File(env[AscEnv.keyP8Path]!).readAsStringSync();
    final client = AscApiClient(
      http: http,
      token: AscJwt.generate(
        keyId: env[AscEnv.keyId]!,
        issuerId: env[AscEnv.issuerId]!,
        privateKeyPem: privateKey,
      ),
    );
    final devices = await client.devices();
    out.writeln('\n${devices.length} registered device(s):');
    for (final device in devices) {
      final marker = highlight != null &&
              device.udid.toLowerCase() == highlight.toLowerCase()
          ? ' ←'
          : '';
      out.writeln('  ${device.deviceClass} ${device.platform} | '
          '${device.status} | ${device.udid} | ${device.name}$marker');
    }
    if (highlight != null &&
        !devices.any(
            (device) => device.udid.toLowerCase() == highlight.toLowerCase())) {
      out.writeln('  ! $highlight is not registered yet');
    }
  }

  /// Mentions the env file only when the project actually has one.
  static String _defineHint(String root) =>
      File('$root/env.prod.json').existsSync()
          ? ' --dart-define-from-file=env.prod.json'
          : '';

  static void _requireAscKey(Map<String, String> env) {
    bool set(String name) => (env[name] ?? '').trim().isNotEmpty;
    if (set(AscEnv.keyId) &&
        set(AscEnv.issuerId) &&
        (set(AscEnv.keyP8) || set(AscEnv.keyP8Path))) {
      return;
    }
    throw SetupException(
      'certs authenticates with an App Store Connect API key. Export:\n'
      '  ${AscEnv.keyId}=<key id>\n'
      '  ${AscEnv.issuerId}=<issuer id>\n'
      '  ${AscEnv.keyP8Path}=<path to AuthKey_*.p8>   '
      '(or ${AscEnv.keyP8}=<contents>)\n'
      'Run `easy_setup doctor` for the issuance steps.',
    );
  }
}

/// [DeploySteps] gives streamed steps with dry-run previews; certs needs
/// exactly that and nothing else from the deployers.
class _CertsRunner with DeploySteps {
  @override
  final String projectRoot;
  @override
  final ProcessRunner processes;
  @override
  final bool dryRun;
  @override
  final StringSink out;

  _CertsRunner({
    required this.projectRoot,
    required this.processes,
    required this.dryRun,
    required this.out,
  });
}
