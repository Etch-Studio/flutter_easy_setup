import '../exceptions.dart';

/// `easy_setup setup` — converges the project to the state declared in
/// easy_setup.yaml (service provisioning, native config injection, assets).
///
/// Not implemented yet — planned for milestone M4 (see V2_PLAN.md).
class SetupCommand {
  static Future<int> run({
    String? projectRoot,
    bool dryRun = false,
    String? only,
  }) async {
    throw SetupException(
      "'setup' is not implemented yet — planned for milestone M4 "
      '(see V2_PLAN.md).\n'
      'Available today: init, doctor, flavor, ci-cd.',
    );
  }
}
