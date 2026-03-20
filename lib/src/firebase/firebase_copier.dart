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
      print('  · [dry-run] Would run: flutterfire configure '
          '--project=$projectId --android-package-name=$bundleId '
          '--ios-bundle-id=$bundleId');
      print('  · → $androidOut');
      print('  · → $iosOut');
      return;
    }

    // Ensure output directories exist
    File(p.join(projectRoot, androidOut)).parent.createSync(recursive: true);
    File(p.join(projectRoot, iosOut)).parent.createSync(recursive: true);

    final args = [
      'configure',
      '--project=$projectId',
      '--out=lib/firebase_options_$flavor.dart',
      '--ios-bundle-id=$bundleId',
      '--android-package-name=$bundleId',
      '--ios-out=$iosOut',
      '--android-out=$androidOut',
    ];
    print('  → flutterfire configure --project=$projectId ...');
    print('  · workdir: $projectRoot');

    final process = await Process.start(
      'flutterfire',
      args,
      workingDirectory: projectRoot,
      mode: ProcessStartMode.inheritStdio,
    );

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      print('  ✗ flutterfire failed (exit $exitCode)');
      throw SetupException(
        'flutterfire configure failed for flavor "$flavor" (exit code $exitCode)',
      );
    }

    print('  ✓ configured: $flavor ($projectId)');
  }
}
