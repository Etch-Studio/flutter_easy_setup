import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../doctor/check.dart';
import '../doctor/checks/android_deploy_checks.dart';
import '../doctor/checks/environment_checks.dart';
import '../exceptions.dart';
import '../utils/process_runner.dart';
import 'dart_define_file.dart';
import 'deploy_steps.dart';
import 'play_json_key.dart';
import 'version_resolver.dart';

/// Deploys the Android app to Google Play in one command:
/// preflight → `flutter build appbundle` → `fastlane supply`.
///
/// The app record and the very first AAB upload are manual (no Play API for
/// them — V2_PLAN.md §6.2); everything after that is automated here.
class AndroidDeployer with DeploySteps {
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

  /// Play track override; defaults to `android.play_track_default`.
  final String? track;

  AndroidDeployer({
    required this.projectRoot,
    required this.config,
    required this.env,
    this.processes = const ProcessRunner(),
    this.dryRun = false,
    this.track,
    StringSink? out,
    bool? isMacOS,
  })  : out = out ?? stdout,
        isMacOS = isMacOS ?? Platform.isMacOS;

  AndroidConfig get _android {
    final android = config.android;
    if (android == null) {
      throw SetupException(
        "easy_setup.yaml has no 'android' section — add one (even an empty "
        "'android:') to deploy to Google Play.",
      );
    }
    return android;
  }

  String get _aabPath => p.join(
      projectRoot, 'build', 'app', 'outputs', 'bundle', 'release',
      'app-release.aab');

  bool _verified = false;

  String get _resolvedTrack => track ?? _android.playTrackDefault;

  /// Config validation + preflight, separated from [run] so a multi-platform
  /// deploy can verify every platform before uploading anything.
  Future<void> verifyReady() async {
    final resolvedTrack = _resolvedTrack;
    if (!AndroidConfig.allowedTracks.contains(resolvedTrack)) {
      throw SetupException(
        "Unknown Play track '$resolvedTrack' — allowed: "
        '${AndroidConfig.allowedTracks.join(' | ')}.',
      );
    }
    if (!dryRun) await _preflight();
    _verified = true;
  }

  Future<int> run({String? buildNumberOverride}) async {
    if (!_verified) await verifyReady();
    final resolvedTrack = _resolvedTrack;

    final version = await VersionResolver.resolve(
      projectRoot: projectRoot,
      env: env,
      buildNumberOverride: buildNumberOverride,
      processes: processes,
    );
    _validateVersion(version);
    out.writeln('Deploying ${config.app.name} '
        '(${config.app.packageName}) '
        '${version.buildName}+${version.buildNumber} '
        'to Play track "$resolvedTrack" [version from ${version.source}]');

    final workDir = dryRun
        ? null
        : Directory.systemTemp.createTempSync('easy_setup_deploy_android');
    try {
      final jsonKeyPath = _resolveJsonKey(workDir);
      await _buildAppBundle(version);
      _requireAab();
      await _supply(resolvedTrack, jsonKeyPath);
    } finally {
      workDir?.deleteSync(recursive: true);
    }

    out.writeln(dryRun
        ? '\n[dry-run] Preview complete — no deploy commands were executed '
            '(version resolution reads git tags).'
        : '\n✓ Uploaded to Google Play ($resolvedTrack track).');
    return 0;
  }

  /// Play's versionCode must be an integer; versionName is free-form, so
  /// only the build number is validated here.
  void _validateVersion(BuildVersion version) {
    if (!RegExp(r'^\d+$').hasMatch(version.buildNumber)) {
      throw SetupException(
        "Build number '${version.buildNumber}' is not numeric — Android "
        'versionCode must be an integer.',
      );
    }
  }

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
            fix: 'Install Flutter: '
                'https://docs.flutter.dev/get-started/install',
          ),
          ToolCheck(
            title: 'Fastlane',
            command: 'fastlane',
            fix: 'brew install fastlane (macOS) or gem install fastlane',
          ),
          PlayServiceAccountCheck(),
        ],
      );

  /// `PLAY_SERVICE_ACCOUNT_JSON` holds either a path or raw JSON; raw JSON
  /// is materialized as an ephemeral file for fastlane's --json_key.
  String _resolveJsonKey(Directory? workDir) {
    if (dryRun) return '<play_service_account.json>';
    return resolvePlayJsonKey(workDir!, env);
  }

  Future<void> _buildAppBundle(BuildVersion version) {
    final defineFile =
        DartDefineFile.resolve(projectRoot: projectRoot, config: config);
    if (defineFile == null) {
      final note = DartDefineFile.missingNote(config);
      if (note != null) out.writeln('  ! $note');
    }
    return step(
      'flutter build appbundle',
      'flutter',
      [
        'build',
        'appbundle',
        '--release',
        '--build-name=${version.buildName}',
        '--build-number=${version.buildNumber}',
        ...DartDefineFile.arguments(defineFile),
      ],
    );
  }

  void _requireAab() {
    if (dryRun) return;
    if (!File(_aabPath).existsSync()) {
      throw SetupException('No app bundle found at $_aabPath after the build.');
    }
  }

  Future<void> _supply(String resolvedTrack, String jsonKeyPath) {
    // Upload images/screenshots when the M5 pipeline has produced them
    // (fastlane/metadata/android/...); otherwise skip so supply does not
    // wipe what is already on the Play listing.
    final hasStoreAssets = Directory(
            p.join(projectRoot, 'fastlane', 'metadata', 'android'))
        .existsSync();
    return step(
      'fastlane supply (Google Play upload)',
      'fastlane',
      [
        'supply',
        '--aab',
        dryRun ? '<build/app/outputs/bundle/release/app-release.aab>'
            : _aabPath,
        '--package_name',
        config.app.packageName,
        '--track',
        resolvedTrack,
        '--json_key',
        jsonKeyPath,
        // Listing texts belong to `setup --only store`, which uploads them
        // from easy_setup_store_info.yaml; a build must not rewrite them.
        // skip_upload_metadata does NOT cover changelogs.
        '--skip_upload_metadata',
        'true',
        '--skip_upload_changelogs',
        'true',
        '--skip_upload_images',
        '${!hasStoreAssets}',
        '--skip_upload_screenshots',
        '${!hasStoreAssets}',
      ],
    );
  }
}
