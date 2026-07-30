import 'dart:io';

import '../config/project_config.dart';
import '../doctor/check.dart';
import '../doctor/doctor_runner.dart';
import '../exceptions.dart';
import '../utils/project_finder.dart';

/// `easy_setup doctor` — verifies the environment, keys, and secrets, and
/// explains how to obtain anything that is missing.
class DoctorCommand {
  /// Runs all doctor checks and prints the report to [out].
  ///
  /// Returns exit code 1 when any check reports an error, otherwise 0.
  static Future<int> run({String? projectRoot, StringSink? out}) async {
    final sink = out ?? stdout;

    final root = ProjectFinder.findFlutterRoot(projectRoot);
    ProjectConfig? config;
    SetupException? configError;
    var configFileExists = false;
    if (root != null) {
      final configPath = ProjectFinder.configPath(root);
      configFileExists = File(configPath).existsSync();
      if (configFileExists) {
        try {
          config = ProjectConfig.fromFile(configPath);
        } on SetupException catch (e) {
          configError = e;
        }
      }
    }

    final context = DoctorContext(
      projectRoot: root,
      config: config,
      configError: configError,
      configFileExists: configFileExists,
      env: Platform.environment,
      isMacOS: Platform.isMacOS,
    );

    sink.writeln('easy_setup doctor');
    sink.writeln();
    final report = await DoctorRunner(context).run();
    sink.write(report.render());
    return report.hasErrors ? 1 : 0;
  }
}
