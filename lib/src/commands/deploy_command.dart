import '../exceptions.dart';

/// `easy_setup deploy` — builds and uploads to the stores. Runs the same
/// code locally and in CI (CI workflows call this command internally).
///
/// Not implemented yet — planned for milestones M2 (iOS) and M3 (Android),
/// see V2_PLAN.md.
class DeployCommand {
  static Future<int> run({
    String? projectRoot,
    bool dryRun = false,
    String? platform,
  }) async {
    throw SetupException(
      "'deploy' is not implemented yet — planned for milestones M2 (iOS) "
      'and M3 (Android), see V2_PLAN.md.\n'
      'Available today: init, doctor, flavor, ci-cd.',
    );
  }
}
