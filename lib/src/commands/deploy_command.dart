import 'dart:io';

import '../config/project_config.dart';
import '../deploy/ios_deployer.dart';
import '../exceptions.dart';
import '../utils/project_finder.dart';

/// `easy_setup deploy` — builds and uploads to the stores. Runs the same
/// code locally and in CI (CI workflows call this command internally).
///
/// iOS (M2): preflight → match → `flutter build ipa` → TestFlight upload.
/// Android is planned for milestone M3 (see V2_PLAN.md).
class DeployCommand {
  static Future<int> run({
    String? projectRoot,
    bool dryRun = false,
    String? platform,
    String? buildNumber,
    bool? matchReadonly,
    StringSink? out,
  }) async {
    final root = ProjectFinder.findFlutterRoot(projectRoot);
    if (root == null) {
      throw SetupException(
        'Could not find a Flutter project root. '
        'Run inside a Flutter project, or pass --project-root <path>.',
      );
    }
    final config = ProjectConfig.fromFile(ProjectFinder.configPath(root));

    final targets = platform != null
        ? [platform]
        : [
            if (config.ios != null) 'ios',
            if (config.android != null) 'android',
          ];
    if (targets.isEmpty) {
      throw SetupException(
        "Nothing to deploy — add an 'ios' section to easy_setup.yaml "
        '(Android deploy lands in M3).',
      );
    }
    if (targets.contains('android')) {
      throw SetupException(
        'Android deploy is not implemented yet — planned for milestone M3 '
        '(see V2_PLAN.md).'
        '${platform == null ? ' Use --platform ios to deploy iOS only.' : ''}',
      );
    }

    return IosDeployer(
      projectRoot: root,
      config: config,
      env: Platform.environment,
      dryRun: dryRun,
      matchReadonly: matchReadonly,
      out: out,
    ).run(buildNumberOverride: buildNumber);
  }
}
