import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions.dart';

/// Configures Firebase for each flavor using FlutterFire CLI.
///
/// Runs `flutterfire configure` per flavor to download config files:
///   Android: google-services.json → android/app/src/{flavor}/google-services.json
///   iOS: GoogleService-Info.plist → ios/Runner/Firebase/{flavor}/GoogleService-Info.plist
class FirebaseConfigurator {
  /// Configures Firebase for a single flavor using FlutterFire CLI.
  ///
  /// Runs `flutterfire configure` with the given [projectId] and [bundleId].
  /// Downloads google-services.json and GoogleService-Info.plist to per-flavor directories.
  static Future<void> configure(
    String projectRoot,
    String flavor,
    String projectId,
    String bundleId, {
    bool dryRun = false,
  }) async {
    final androidOut = p.join(
      'android', 'app', 'src', flavor, 'google-services.json',
    );
    final iosOut = p.join(
      'ios', 'Runner', 'Firebase', flavor, 'GoogleService-Info.plist',
    );

    if (dryRun) {
      print('  [dry-run] Would run: flutterfire configure '
          '--project=$projectId --android-package-name=$bundleId '
          '--ios-bundle-id=$bundleId');
      print('    → $androidOut');
      print('    → $iosOut');
      return;
    }

    // Ensure output directories exist
    File(p.join(projectRoot, androidOut)).parent.createSync(recursive: true);
    File(p.join(projectRoot, iosOut)).parent.createSync(recursive: true);

    final result = await Process.run(
      'flutterfire',
      [
        'configure',
        '--project=$projectId',
        '--android-package-name=$bundleId',
        '--ios-bundle-id=$bundleId',
        '--android-out=$androidOut',
        '--ios-out=$iosOut',
        '--out=lib/firebase_options_$flavor.dart',
        '--yes',
        '--platforms=android,ios',
      ],
      workingDirectory: projectRoot,
    );

    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      throw SetupException(
        'flutterfire configure failed for flavor "$flavor":\n'
        '${stderr.isNotEmpty ? stderr : result.stdout}',
      );
    }

    print('  Firebase configured for $flavor (project: $projectId)');
  }
}
