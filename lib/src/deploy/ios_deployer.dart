import 'dart:io';

import 'package:path/path.dart' as p;

import '../appstore/asc_api_key_file.dart';
import '../config/project_config.dart';
import '../doctor/check.dart';
import '../doctor/checks/environment_checks.dart';
import '../doctor/checks/ios_deploy_checks.dart';
import '../exceptions.dart';
import '../utils/process_runner.dart';
import 'dart_define_file.dart';
import 'deploy_steps.dart';
import 'version_resolver.dart';

/// Deploys the iOS app to TestFlight in one command:
/// preflight → `fastlane match` → `flutter build ipa` → `fastlane pilot`.
///
/// The same code path runs locally and in CI (V2_PLAN.md §3): everything is
/// driven by easy_setup.yaml and the ASC_*/MATCH_* environment variables.
class IosDeployer with DeploySteps {
  @override
  final String projectRoot;
  final ProjectConfig config;
  final Map<String, String> env;
  @override
  final ProcessRunner processes;
  @override
  final bool dryRun;
  @override
  final StringSink out;
  final bool isMacOS;

  /// Whether `fastlane match` runs read-only. Null = auto: read-only in CI
  /// (fastlane's recommendation — signing assets are bootstrapped locally),
  /// write mode locally.
  final bool? matchReadonly;

  /// Submit the uploaded build for App Store review after TestFlight
  /// (`deploy --submit`) — opt-in, submissions are hard to undo.
  final bool submit;

  IosDeployer({
    required this.projectRoot,
    required this.config,
    required this.env,
    this.processes = const ProcessRunner(),
    this.dryRun = false,
    this.matchReadonly,
    this.submit = false,
    StringSink? out,
    bool? isMacOS,
  })  : out = out ?? stdout,
        isMacOS = isMacOS ?? Platform.isMacOS;

  bool get _matchReadonly => matchReadonly ?? env['CI'] == 'true';

  IosConfig get _ios {
    final ios = config.ios;
    if (ios == null) {
      throw SetupException(
        "easy_setup.yaml has no 'ios' section — nothing to deploy for iOS.",
      );
    }
    return ios;
  }

  bool _verified = false;

  /// Config validation + preflight, separated from [run] so a multi-platform
  /// deploy can verify every platform before uploading anything.
  Future<void> verifyReady() async {
    _requireConfigured(_ios);
    if (!dryRun) await _preflight();
    _verified = true;
  }

  Future<int> run({String? buildNumberOverride}) async {
    if (!_verified) await verifyReady();
    final ios = _ios;

    final version = await VersionResolver.resolve(
      projectRoot: projectRoot,
      env: env,
      buildNumberOverride: buildNumberOverride,
      processes: processes,
    );
    _validateVersion(version);
    out.writeln('Deploying ${config.app.name} '
        '(${config.app.bundleId}) ${version.buildName}+${version.buildNumber} '
        '[version from ${version.source}]');

    // Ephemeral signing inputs live in a private temp dir for the duration
    // of the deploy.
    final workDir =
        dryRun ? null : Directory.systemTemp.createTempSync('easy_setup_deploy');
    try {
      final apiKeyPath = _writeApiKeyJson(workDir);
      await _match(ios, apiKeyPath);
      await _configureSigning(ios);
      final exportOptionsPath = _writeExportOptions(workDir, ios);
      _cleanIpaOutput();
      await _buildIpa(version, exportOptionsPath);
      final ipaPath = _findIpa();
      await _pilotUpload(ipaPath, apiKeyPath);
      if (submit) await _submitForReview(version, apiKeyPath);
    } finally {
      workDir?.deleteSync(recursive: true);
    }

    out.writeln(dryRun
        ? '\n[dry-run] Preview complete — no deploy commands were executed '
            '(version resolution reads git tags).'
        : '\n✓ Uploaded to TestFlight.');
    return 0;
  }

  /// iOS rejects non-numeric versions: CFBundleShortVersionString must be
  /// `x.y.z` and CFBundleVersion numeric. Failing here beats failing 10
  /// minutes into `flutter build ipa`.
  void _validateVersion(BuildVersion version) {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version.buildName)) {
      throw SetupException(
        "Version '${version.buildName}' (from ${version.source}) is not a "
        'valid iOS CFBundleShortVersionString — use plain x.y.z '
        '(pre-release suffixes like -beta.1 are not accepted by the '
        'App Store).',
      );
    }
    if (!RegExp(r'^\d+$').hasMatch(version.buildNumber)) {
      throw SetupException(
        "Build number '${version.buildNumber}' is not numeric — iOS "
        'CFBundleVersion must be an integer.',
      );
    }
  }

  /// Config values deploy cannot proceed without.
  void _requireConfigured(IosConfig ios) {
    final missing = <String>[
      if (ios.teamId == null) 'ios.team_id',
      if (ios.matchGitUrl == null) 'ios.match_git_url',
    ];
    if (missing.isNotEmpty) {
      throw SetupException(
        'iOS deploy needs ${missing.join(' and ')} in easy_setup.yaml.',
      );
    }
  }

  /// Runs the doctor checks deploy depends on and aborts on any error.
  Future<void> _preflight() => preflight(
        DoctorContext(
          projectRoot: projectRoot,
          config: config,
          configFileExists: true,
          env: env,
          processes: processes,
          isMacOS: isMacOS,
        ),
        [
          ToolCheck(
            title: 'Flutter SDK',
            command: 'flutter',
            fix:
                'Install Flutter: https://docs.flutter.dev/get-started/install',
          ),
          ToolCheck(
            title: 'Fastlane',
            command: 'fastlane',
            fix: 'brew install fastlane',
          ),
          AscApiKeyCheck(),
          MatchCheck(),
        ],
      );

  /// Writes the fastlane API key JSON (used by match/pilot/deliver via
  /// --api_key_path). Returns a placeholder path in dry-run mode.
  String _writeApiKeyJson(Directory? workDir) {
    if (dryRun) return '<api_key.json>';
    return writeAscApiKeyJson(workDir!, env);
  }

  /// ExportOptions.plist for `flutter build ipa` — manual signing with the
  /// match-provisioned App Store profile.
  String _writeExportOptions(Directory? workDir, IosConfig ios) {
    if (dryRun) return '<ExportOptions.plist>';
    final bundleId = config.app.bundleId;
    final file = File(p.join(workDir!.path, 'ExportOptions.plist'));
    file.writeAsStringSync(exportOptionsPlist(
      teamId: ios.teamId!,
      bundleId: bundleId,
    ));
    return file.path;
  }

  static String exportOptionsPlist({
    required String teamId,
    required String bundleId,
  }) =>
      '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store</string>
  <key>teamID</key>
  <string>$teamId</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$bundleId</key>
    <string>match AppStore $bundleId</string>
  </dict>
</dict>
</plist>
''';

  Future<void> _match(IosConfig ios, String apiKeyPath) => step(
        'fastlane match (certificates & provisioning profiles)',
        'fastlane',
        [
          'match',
          'appstore',
          '--app_identifier',
          config.app.bundleId,
          '--git_url',
          ios.matchGitUrl!,
          '--team_id',
          ios.teamId!,
          '--api_key_path',
          apiKeyPath,
          '--readonly',
          '$_matchReadonly',
        ],
      );

  /// Switches the Runner target to manual signing with the match profile.
  /// ExportOptions.plist alone only covers the export step — the archive
  /// step uses the Xcode project's own signing settings.
  Future<void> _configureSigning(IosConfig ios) => step(
        'configure manual signing (Runner.xcodeproj)',
        'fastlane',
        [
          'run',
          'update_code_signing_settings',
          'use_automatic_signing:false',
          'path:ios/Runner.xcodeproj',
          'team_id:${ios.teamId!}',
          'code_sign_identity:Apple Distribution',
          'bundle_identifier:${config.app.bundleId}',
          'profile_name:match AppStore ${config.app.bundleId}',
        ],
      );

  /// Removes previous .ipa artifacts so a stale binary can never be picked
  /// up by the upload step.
  void _cleanIpaOutput() {
    if (dryRun) return;
    final ipaDir = Directory(p.join(projectRoot, 'build', 'ios', 'ipa'));
    if (ipaDir.existsSync()) ipaDir.deleteSync(recursive: true);
  }

  Future<void> _buildIpa(BuildVersion version, String exportOptionsPath) {
    final defineFile =
        DartDefineFile.resolve(projectRoot: projectRoot, config: config);
    if (defineFile == null) {
      final note = DartDefineFile.missingNote(config);
      if (note != null) out.writeln('  ! $note');
    }
    return step(
      'flutter build ipa',
      'flutter',
      [
        'build',
        'ipa',
        '--release',
        '--build-name=${version.buildName}',
        '--build-number=${version.buildNumber}',
        '--export-options-plist=$exportOptionsPath',
        ...DartDefineFile.arguments(defineFile),
      ],
    );
  }

  String _findIpa() {
    if (dryRun) return '<build/ios/ipa/*.ipa>';
    final ipaDir = Directory(p.join(projectRoot, 'build', 'ios', 'ipa'));
    final ipas = ipaDir.existsSync()
        ? (ipaDir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.ipa'))
            .toList()
          ..sort((a, b) => b
              .lastModifiedSync()
              .compareTo(a.lastModifiedSync())))
        : <File>[];
    if (ipas.isEmpty) {
      throw SetupException(
        'No .ipa found under ${ipaDir.path} after the build.',
      );
    }
    return ipas.first.path;
  }

  /// Submits the just-uploaded build for review. Metadata/screenshots are
  /// managed by `setup --only store` and are not re-uploaded here.
  Future<void> _submitForReview(BuildVersion version, String apiKeyPath) =>
      step(
        'fastlane deliver (submit for review)',
        'fastlane',
        [
          'deliver',
          '--skip_binary_upload', 'true',
          '--skip_metadata', 'true',
          '--skip_screenshots', 'true',
          '--submit_for_review', 'true',
          '--automatic_release', 'false',
          '--run_precheck_before_submit', 'false',
          '--force', 'true',
          '--api_key_path', apiKeyPath,
          '--app_identifier', config.app.bundleId,
          '--app_version', version.buildName,
          '--build_number', version.buildNumber,
        ],
      );

  Future<void> _pilotUpload(String ipaPath, String apiKeyPath) => step(
        'fastlane pilot (TestFlight upload)',
        'fastlane',
        [
          'pilot',
          'upload',
          '--ipa',
          ipaPath,
          '--api_key_path',
          apiKeyPath,
          // A review submission needs a fully processed build — wait for
          // processing when --submit follows.
          '--skip_waiting_for_build_processing',
          '${!submit}',
        ],
      );

}
