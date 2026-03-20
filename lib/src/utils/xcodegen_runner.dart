import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions.dart';

/// Utility class for running the xcodegen CLI.
///
/// Invokes the `xcodegen generate` command to generate
/// an Xcode project (project.pbxproj, schemes, etc.) from project.yml.
class XcodeGenRunner {
  /// Runs xcodegen generate.
  ///
  /// [projectRoot]: Flutter project root.
  /// Runs in the ios/ directory where project.yml is located.
  static void run(String projectRoot, {bool dryRun = false}) {
    final iosDir = p.join(projectRoot, 'ios');
    final projectYmlPath = p.join(iosDir, 'project.yml');

    if (dryRun) {
      print('  [dry-run] Would run: xcodegen generate (in $iosDir)');
      return;
    }

    if (!File(projectYmlPath).existsSync()) {
      throw SetupException(
        'project.yml not found at $projectYmlPath\n'
        'Run the flavor setup first to generate project.yml.',
      );
    }

    // Check if xcodegen is installed
    final which = Process.runSync('which', ['xcodegen']);
    if (which.exitCode == 0) {
      print('  xcodegen found at: ${(which.stdout as String).trim()}');
    }
    if (which.exitCode != 0) {
      print('  WARNING: xcodegen is not installed.');
      print('  Install it with: brew install xcodegen');
      print('  Then run: cd ios && xcodegen generate');
      print('  See: https://github.com/yonaskolb/XcodeGen');
      return;
    }

    print('  Running: xcodegen generate');
    final result = Process.runSync(
      'xcodegen',
      ['generate'],
      workingDirectory: iosDir,
    );

    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      if (stderr.isNotEmpty) print('  stderr: $stderr');
      throw SetupException(
        'xcodegen generate failed (exit code ${result.exitCode}):\n$stderr',
      );
    }

    final stdout = (result.stdout as String).trim();
    final stderr = (result.stderr as String).trim();
    if (stdout.isNotEmpty) print('  stdout: $stdout');
    if (stderr.isNotEmpty) print('  stderr: $stderr');
    print('  Xcode project generated successfully.');
  }
}
