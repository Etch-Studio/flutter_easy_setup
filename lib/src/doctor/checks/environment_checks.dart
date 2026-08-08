import '../../render/html_renderer.dart';
import '../check.dart';

/// Verifies a CLI tool is installed and reports its version.
class ToolCheck extends DoctorCheck {
  final String title;
  final String command;
  final List<String> versionArguments;

  /// Picks the output line to report as the version (see
  /// [ProcessRunner.versionOf]); the first non-empty line when null.
  final Pattern? versionLinePattern;

  /// Install guidance shown when the tool is missing.
  final String fix;

  /// When true a missing tool is a warning, not an error.
  final bool optional;

  @override
  final String category;

  ToolCheck({
    required this.title,
    required this.command,
    required this.fix,
    this.versionArguments = const ['--version'],
    this.versionLinePattern,
    this.optional = false,
    this.category = DoctorCategory.environment,
  });

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final path = await context.processes.which(command);
    if (path == null) {
      return optional
          ? CheckResult.warning(title, detail: 'not installed', fix: fix)
          : CheckResult.error(title, detail: 'not installed', fix: fix);
    }
    final version = await context.processes.versionOf(
      command,
      arguments: versionArguments,
      linePattern: versionLinePattern,
    );
    return CheckResult.ok(title, detail: version ?? path);
  }
}

/// Chrome renders the store assets (icon SVGs, marketing screenshots).
/// It is not on PATH in a normal macOS install, so [ToolCheck] cannot find
/// it — this resolves it the same way the renderer does.
class StoreAssetRendererCheck extends DoctorCheck {
  @override
  String get category => DoctorCategory.environment;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'Chrome (store asset renderer)';
    final executable = await ChromeRenderer(
      processes: context.processes,
      env: context.env,
    ).findExecutable();
    if (executable == null) {
      return CheckResult.warning(
        title,
        detail: 'not found',
        fix: 'Needed by the branding and screenshots setup steps.\n'
            '${ChromeRenderer.installHint}',
      );
    }
    return CheckResult.ok(title, detail: executable);
  }
}
