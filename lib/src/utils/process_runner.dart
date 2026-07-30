import 'dart:io';

/// Thin wrapper around [Process.run] so commands and doctor checks can be
/// tested with a fake implementation.
class ProcessRunner {
  const ProcessRunner();

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) =>
      Process.run(executable, arguments, workingDirectory: workingDirectory);

  /// Runs a long-lived command with stdout/stderr streamed straight to the
  /// terminal (fastlane, flutter build, ...). Returns the exit code.
  Future<int> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }

  /// Resolves [command] on PATH, or returns null when not found.
  Future<String?> which(String command) async {
    try {
      final result =
          await run(Platform.isWindows ? 'where' : 'which', [command]);
      if (result.exitCode != 0) return null;
      final output = (result.stdout as String).trim();
      if (output.isEmpty) return null;
      return output.split('\n').first.trim();
    } on ProcessException {
      return null;
    }
  }

  /// Runs `command <args>` and returns the first non-empty output line
  /// (checking stdout, then stderr — some tools print versions to stderr),
  /// or null when the command fails.
  ///
  /// When [linePattern] is given, the first matching line is preferred over
  /// the first non-empty one (useful for tools that print a preamble, like
  /// fastlane).
  Future<String?> versionOf(
    String command, {
    List<String> arguments = const ['--version'],
    Pattern? linePattern,
  }) async {
    try {
      final result = await run(command, arguments);
      if (result.exitCode != 0) return null;
      final lines = [result.stdout as String, result.stderr as String]
          .expand((stream) => stream.split('\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty);
      if (linePattern != null) {
        for (final line in lines) {
          if (line.contains(linePattern)) return line;
        }
      }
      return lines.firstOrNull;
    } on ProcessException {
      return null;
    }
  }
}
