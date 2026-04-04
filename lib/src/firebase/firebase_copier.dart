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
          '--project=$projectId --platforms=android,ios '
          '--android-package-name=$bundleId --ios-bundle-id=$bundleId');
      print('  · → $androidOut');
      print('  · → $iosOut');
      return;
    }

    // Ensure output directories exist
    File(p.join(projectRoot, androidOut)).parent.createSync(recursive: true);
    File(p.join(projectRoot, iosOut)).parent.createSync(recursive: true);

    // Backup existing firebase_options file so we can restore on failure
    final optionsPath = p.join(projectRoot, 'lib', 'firebase_options_$flavor.dart');
    final optionsFile = File(optionsPath);
    final backupPath = '$optionsPath.bak';
    final hadBackup = optionsFile.existsSync();
    if (hadBackup) {
      optionsFile.copySync(backupPath);
      optionsFile.deleteSync();
      print('  · backed up: lib/firebase_options_$flavor.dart');
    }

    final args = [
      'configure',
      '--project=$projectId',
      '--out=lib/firebase_options_$flavor.dart',
      '--platforms=android,ios',
      '--ios-bundle-id=$bundleId',
      '--android-package-name=$bundleId',
      '--ios-out=$iosOut',
      '--android-out=$androidOut',
      '--ios-build-config=Debug-$flavor',
    ];
    print('  → flutterfire ${args.join(' ')}');
    print('  · workdir: $projectRoot');

    void restoreBackup() {
      if (hadBackup) {
        final backup = File(backupPath);
        if (backup.existsSync()) {
          backup.copySync(optionsPath);
          backup.deleteSync();
        }
        print('  · restored: lib/firebase_options_$flavor.dart');
      }
    }

    int exitCode;
    try {
      final process = await Process.start(
        'flutterfire',
        args,
        workingDirectory: projectRoot,
        mode: ProcessStartMode.inheritStdio,
      );
      exitCode = await process.exitCode;
    } catch (e) {
      restoreBackup();
      print('  ✗ flutterfire failed to start: $e');
      throw SetupException(
        'flutterfire configure failed for flavor "$flavor": $e',
      );
    }

    if (exitCode != 0) {
      restoreBackup();
      print('  ✗ flutterfire failed (exit $exitCode)');
      throw SetupException(
        'flutterfire configure failed for flavor "$flavor" (exit code $exitCode)',
      );
    }

    // Clean up backup on success
    final backup = File(backupPath);
    if (backup.existsSync()) backup.deleteSync();

    print('  ✓ configured: $flavor ($projectId)');
  }
}
