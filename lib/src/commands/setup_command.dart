import 'dart:io';

import '../config/project_config.dart';
import '../exceptions.dart';
import '../setup/admob_step.dart';
import '../setup/firebase_step.dart';
import '../setup/ios_capabilities_step.dart';
import '../setup/sentry_step.dart';
import '../setup/setup_step.dart';
import '../utils/http_json_client.dart';
import '../utils/process_runner.dart';
import '../utils/project_finder.dart';

/// `easy_setup setup` — converges the project to the state declared in
/// easy_setup.yaml. Every step is idempotent; `--only <step>` runs one.
///
/// Steps: sentry, firebase, admob, ios_capabilities.
class SetupCommand {
  /// Registered steps in execution order.
  static List<SetupStep> defaultSteps() => [
        SentryStep(),
        FirebaseStep(),
        AdmobStep(),
        IosCapabilitiesStep(),
      ];

  static Future<int> run({
    String? projectRoot,
    bool dryRun = false,
    String? only,
    StringSink? out,
    Map<String, String>? env,
    ProcessRunner processes = const ProcessRunner(),
    HttpJsonClient? http,
    List<SetupStep>? steps,
  }) async {
    final root = ProjectFinder.findFlutterRoot(projectRoot);
    if (root == null) {
      throw SetupException(
        'Could not find a Flutter project root. '
        'Run inside a Flutter project, or pass --project-root <path>.',
      );
    }
    final config = ProjectConfig.fromFile(ProjectFinder.configPath(root));
    final sink = out ?? stdout;

    var selected = steps ?? defaultSteps();
    if (only != null) {
      final known = selected.map((step) => step.name).toList();
      selected =
          selected.where((step) => step.name == only).toList();
      if (selected.isEmpty) {
        throw SetupException(
          "Unknown setup step '$only' — available: ${known.join(', ')}.",
        );
      }
    }

    final context = SetupContext(
      projectRoot: root,
      config: config,
      env: env ?? Platform.environment,
      processes: processes,
      http: http,
      dryRun: dryRun,
      out: sink,
    );

    var ran = 0;
    for (final step in selected) {
      if (!step.isConfigured(config)) {
        if (only != null) {
          throw SetupException(
            "Setup step '${step.name}' needs its section in "
            'easy_setup.yaml, which is not configured.',
          );
        }
        sink.writeln(
            '- ${step.name}: skipped (section not in easy_setup.yaml)');
        continue;
      }
      sink.writeln('\n--- ${step.name} ---');
      await step.run(context);
      ran++;
    }

    if (ran == 0) {
      sink.writeln(
          '\nNothing to do — uncomment the sections you need in '
          'easy_setup.yaml (sentry, admob, ...).');
    } else {
      sink.writeln(dryRun
          ? '\n[dry-run] Preview complete — no files or APIs were touched.'
          : '\n✓ Setup complete ($ran step(s)).');
    }
    return 0;
  }
}
