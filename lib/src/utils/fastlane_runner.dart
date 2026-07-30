import 'dart:io';

import '../exceptions.dart';

/// Utility for preparing the Fastlane execution environment and running commands.
///
/// Runs `bundle install` in the fastlane directory and
/// executes commands via `bundle exec fastlane`.
class FastlaneRunner {
  /// Runs `bundle install` in [fastlaneDir].
  static Future<void> bundleInstall(String fastlaneDir,
      {bool dryRun = false}) async {
    if (dryRun) {
      print('  [dry-run] Would run: bundle install');
      return;
    }

    print('  → bundle install (dir: $fastlaneDir)');
    final result = await Process.run(
      'bundle',
      ['install'],
      workingDirectory: fastlaneDir,
    );

    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      throw SetupException(
        'bundle install failed:\n'
        '${stderr.isNotEmpty ? stderr : (result.stdout as String).trim()}',
      );
    }
    print('  bundle install complete');
  }

  /// Runs a command via `bundle exec fastlane`.
  ///
  /// Additional environment variables can be passed via [environment].
  static Future<ProcessResult> run(
    String fastlaneDir,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    return Process.run(
      'bundle',
      ['exec', 'fastlane', ...args],
      workingDirectory: fastlaneDir,
      environment: environment,
      includeParentEnvironment: true,
    );
  }
}
