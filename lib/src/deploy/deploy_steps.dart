import '../doctor/check.dart';
import '../exceptions.dart';
import '../utils/process_runner.dart';

/// Shared machinery for platform deployers: streamed step execution with
/// dry-run previews, and a doctor-based preflight gate.
mixin DeploySteps {
  String get projectRoot;
  ProcessRunner get processes;
  bool get dryRun;
  StringSink get out;

  /// Runs one deploy step, streaming output; in dry-run mode only prints
  /// the command that would run.
  Future<void> step(
    String title,
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    out.writeln('\n--- $title ---');
    if (dryRun) {
      out.writeln('  [dry-run] Would run: $executable ${arguments.join(' ')}');
      return;
    }
    final exitCode = await processes.stream(
      executable,
      arguments,
      workingDirectory: projectRoot,
      environment: environment,
    );
    if (exitCode != 0) {
      throw SetupException('$title failed (exit code $exitCode).');
    }
  }

  /// Runs [checks] and throws with the collected failures when any of them
  /// reports an error.
  Future<void> preflight(DoctorContext context, List<DoctorCheck> checks) async {
    final failures = <CheckResult>[];
    for (final check in checks) {
      final result = await check.run(context);
      if (result.status == CheckStatus.error) failures.add(result);
    }
    if (failures.isNotEmpty) {
      final report = failures.map((result) {
        final fix = result.fix == null ? '' : '\n${result.fix}';
        return '✗ ${result.title}: ${result.detail ?? 'failed'}$fix';
      }).join('\n');
      throw SetupException(
        'Deploy preflight failed:\n$report\n\n'
        'Run `easy_setup doctor` for the full report.',
      );
    }
  }
}
