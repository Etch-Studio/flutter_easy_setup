import 'dart:io';

import '../config/project_config.dart';
import '../deploy/android_deployer.dart';
import '../deploy/ios_deployer.dart';
import '../exceptions.dart';
import '../utils/process_runner.dart';
import '../utils/project_finder.dart';

/// `easy_setup deploy` — builds and uploads to the stores. Runs the same
/// code locally and in CI (CI workflows call this command internally).
///
/// iOS (M2): preflight → match → `flutter build ipa` → TestFlight upload.
/// Android (M3): preflight → `flutter build appbundle` → Play upload.
class DeployCommand {
  static Future<int> run({
    String? projectRoot,
    bool dryRun = false,
    String? platform,
    String? buildNumber,
    bool? matchReadonly,
    bool submit = false,
    String? track,

    /// CI mode: an explicitly requested platform whose section is missing is
    /// skipped (exit 0) instead of failing — the generated caller workflow
    /// runs both platform jobs unconditionally.
    bool ifConfigured = false,
    StringSink? out,
    Map<String, String>? env,
    ProcessRunner processes = const ProcessRunner(),
  }) async {
    final root = ProjectFinder.findFlutterRoot(projectRoot);
    if (root == null) {
      throw SetupException(
        'Could not find a Flutter project root. '
        'Run inside a Flutter project, or pass --project-root <path>.',
      );
    }
    final config = ProjectConfig.fromFile(ProjectFinder.configPath(root));
    final sink = out ?? stdout;
    final environment = env ?? Platform.environment;

    if (platform != null &&
        ifConfigured &&
        ((platform == 'ios' && config.ios == null) ||
            (platform == 'android' && config.android == null))) {
      sink.writeln(
        "Skipping $platform — no '$platform' section in easy_setup.yaml.",
      );
      return 0;
    }

    final targets = platform != null
        ? [platform]
        : [
            if (config.ios != null) 'ios',
            if (config.android != null) 'android',
          ];
    if (targets.isEmpty) {
      throw SetupException(
        "Nothing to deploy — add an 'ios' and/or 'android' section to "
        'easy_setup.yaml.',
      );
    }

    final deployers = <(String, Future<void> Function(), Future<int> Function())>[
      for (final target in targets)
        switch (target) {
          'ios' => () {
              final deployer = IosDeployer(
                projectRoot: root,
                config: config,
                env: environment,
                processes: processes,
                dryRun: dryRun,
                matchReadonly: matchReadonly,
                submit: submit,
                out: out,
              );
              return (
                target,
                deployer.verifyReady,
                () => deployer.run(buildNumberOverride: buildNumber),
              );
            }(),
          'android' => () {
              final deployer = AndroidDeployer(
                projectRoot: root,
                config: config,
                env: environment,
                processes: processes,
                dryRun: dryRun,
                track: track,
                out: out,
              );
              return (
                target,
                deployer.verifyReady,
                () => deployer.run(buildNumberOverride: buildNumber),
              );
            }(),
          _ => throw SetupException("Unknown platform '$target'."),
        },
    ];

    // Verify every platform before uploading anything — a missing Android
    // secret must not surface after iOS already shipped to TestFlight.
    for (final (_, verify, _) in deployers) {
      await verify();
    }
    for (final (target, _, deploy) in deployers) {
      if (deployers.length > 1) sink.writeln('\n===== $target =====');
      final exitCode = await deploy();
      if (exitCode != 0) return exitCode;
    }
    return 0;
  }
}
