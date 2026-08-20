import '../config/project_config.dart';
import '../exceptions.dart';
import '../utils/http_json_client.dart';
import '../utils/process_runner.dart';

/// Outcome level of a single doctor check.
enum CheckStatus { ok, warning, error, skipped }

/// Result of one doctor check, rendered as a single report line
/// (plus optional fix guidance).
class CheckResult {
  final CheckStatus status;

  /// Short label, e.g. "Flutter SDK" or "App Store Connect API key".
  final String title;

  /// What was found (version string, path, missing variable names, ...).
  final String? detail;

  /// Step-by-step guidance shown when the check did not pass.
  final String? fix;

  const CheckResult._(this.status, this.title, {this.detail, this.fix});

  const CheckResult.ok(String title, {String? detail})
      : this._(CheckStatus.ok, title, detail: detail);

  const CheckResult.warning(String title, {String? detail, String? fix})
      : this._(CheckStatus.warning, title, detail: detail, fix: fix);

  const CheckResult.error(String title, {String? detail, String? fix})
      : this._(CheckStatus.error, title, detail: detail, fix: fix);

  const CheckResult.skipped(String title, {String? detail})
      : this._(CheckStatus.skipped, title, detail: detail);
}

/// Everything a doctor check may inspect. Fully injectable for tests.
class DoctorContext {
  /// Flutter project root, or null when not inside a Flutter project.
  final String? projectRoot;

  /// Parsed easy_setup.yaml, or null when missing or invalid.
  final ProjectConfig? config;

  /// Parse/validation error captured while loading easy_setup.yaml, if any.
  final SetupException? configError;

  /// Whether easy_setup.yaml exists at all (distinguishes "missing file"
  /// from "invalid file" in the report).
  final bool configFileExists;

  /// Environment variables (defaults to `Platform.environment` in the CLI).
  final Map<String, String> env;

  final ProcessRunner processes;

  /// Used by the checks that can only be answered over the network — so far
  /// app-ads.txt, which lives on a host easy_setup never writes to.
  final HttpJsonClient http;

  final bool isMacOS;

  const DoctorContext({
    this.projectRoot,
    this.config,
    this.configError,
    this.configFileExists = false,
    this.env = const {},
    this.processes = const ProcessRunner(),
    this.http = const IoHttpJsonClient(),
    this.isMacOS = true,
  });
}

/// A single verification step run by `easy_setup doctor`.
abstract class DoctorCheck {
  /// Report section this check is grouped under (see [DoctorCategory]).
  String get category;

  Future<CheckResult> run(DoctorContext context);
}

/// Report section names, in display order.
abstract final class DoctorCategory {
  static const environment = 'Environment';
  static const project = 'Project';
  static const iosDeploy = 'iOS deploy';
  static const androidDeploy = 'Android deploy';
  static const integrations = 'Integrations';

  static const ordered = [
    environment,
    project,
    iosDeploy,
    androidDeploy,
    integrations,
  ];
}
