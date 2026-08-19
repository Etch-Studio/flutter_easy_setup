import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';

/// The `--dart-define-from-file` argument a release build needs.
///
/// The Setup Kit writes `SENTRY_DSN`, `AMPLITUDE_API_KEY` and the
/// `ADMOB_*` unit IDs into env.prod.json. A build that does not pass the file
/// compiles every one of them as an empty string, and the SDKs are written to
/// no-op on an empty key — so the failure is silent: the upload succeeds and
/// the app simply reports nothing. Deploy passes it.
class DartDefineFile {
  /// Env file release builds compile with, or null when the project has none.
  ///
  /// A file named in `build.dart_define_file` must exist — falling back
  /// silently there would ship exactly the build this class exists to
  /// prevent. With no config, `env.prod.json` is used when it is there.
  static String? resolve({
    required String projectRoot,
    required ProjectConfig config,
  }) {
    final declared = config.build?.dartDefineFile;
    if (declared != null) {
      if (!File(p.join(projectRoot, declared)).existsSync()) {
        throw SetupException(
          "build.dart_define_file names '$declared', which does not exist in "
          '$projectRoot.\n'
          'Run `easy_setup setup` to generate it, or drop the key to fall '
          'back to ${BuildConfig.defaultDartDefineFile} when present.',
        );
      }
      return declared;
    }
    const fallback = BuildConfig.defaultDartDefineFile;
    return File(p.join(projectRoot, fallback)).existsSync() ? fallback : null;
  }

  /// `flutter build` arguments for [fileName] (empty when it is null).
  static List<String> arguments(String? fileName) =>
      fileName == null ? const [] : ['--dart-define-from-file=$fileName'];

  /// What to tell the user when there is no file to pass — only worth saying
  /// when a step wrote defines the build would have needed.
  static String? missingNote(ProjectConfig config) {
    final sources = [
      if (config.sentry != null) 'sentry',
      if (config.amplitude != null) 'amplitude',
      if (config.admob != null) 'admob',
    ];
    if (sources.isEmpty) return null;
    return 'No ${BuildConfig.defaultDartDefineFile} — building without '
        '--dart-define-from-file, so the values ${sources.join(' / ')} write '
        'compile as empty strings. Run `easy_setup setup` first.';
  }
}
